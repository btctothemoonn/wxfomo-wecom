import AppKit
import Foundation
import WxFomoCore

private enum AppModelAnalysisError: LocalizedError {
  case messageStoreUnavailable
  case noGroupsSelected

  var errorDescription: String? {
    switch self {
    case .messageStoreUnavailable: return "本地消息库不可用"
    case .noGroupsSelected: return "请至少选择一个群聊"
    }
  }
}

private enum CAWatchPoolRuntimeError: LocalizedError {
  case chainUnresolved
  case marketDataIncomplete

  var errorDescription: String? {
    switch self {
    case .chainUnresolved: return "无法唯一识别该地址所在网络"
    case .marketDataIncomplete: return "行情源没有返回币名或市值"
    }
  }
}

private enum CAWatchPoolRefreshOutcome: Sendable {
  case success(identifier: String, snapshot: CATokenMarketSnapshot)
  case failure(identifier: String, message: String, errorCode: String)
  case cancelled
}

private enum ProviderSaveError: LocalizedError {
  case apiKeyRequiredAfterEndpointChange
  case apiKeyRequired

  var errorDescription: String? {
    switch self {
    case .apiKeyRequiredAfterEndpointChange:
      return "修改了服务协议或地址，请重新输入 API Key"
    case .apiKeyRequired:
      return "当前配置中心没有这个服务的 API Key，请重新输入"
    }
  }
}

@MainActor
final class AppModel: ObservableObject {
  struct HistoryDiagnostic: Equatable {
    let decodedNotificationCount: Int
    let matchedGroupCount: Int
    let attachmentCount: Int
  }

  enum KindFilter: String, CaseIterable, Identifiable {
    case all
    case text
    case media

    var id: String { rawValue }

    var title: String {
      switch self {
      case .all: return "全部"
      case .text: return "文字"
      case .media: return "媒体"
      }
    }
  }

  enum AddressFilter: String, CaseIterable, Identifiable {
    case all
    case any
    case ethereum
    case bsc
    case base
    case robinhood
    case solana
    /// Persisted as "evm" for compatibility with existing UserDefaults.
    case unresolved = "evm"
    case webLink = "web_link"

    var id: String { rawValue }

    var title: String {
      switch self {
      case .all: return "全部"
      case .any: return "链上"
      case .unresolved: return "待识别"
      case .ethereum: return "Ethereum"
      case .base: return "Base"
      case .bsc: return "BSC"
      case .robinhood: return "Robinhood"
      case .solana: return "Solana"
      case .webLink: return "链接"
      }
    }

    var systemImage: String {
      switch self {
      case .all: return "line.3.horizontal.decrease"
      case .any: return "link"
      case .unresolved: return "questionmark.circle"
      case .ethereum: return "circle.hexagongrid.circle"
      case .base: return "square.stack.3d.up"
      case .bsc: return "circle.grid.2x2"
      case .robinhood: return "bird"
      case .solana: return "sun.max"
      case .webLink: return "link.badge.plus"
      }
    }
  }

  enum ListenerState: Equatable {
    case idle
    case starting
    case listening
    case recovering(String)
    case failed(String)

    var title: String {
      switch self {
      case .idle: return "已停止"
      case .starting: return "正在连接"
      case .listening: return "正在监听"
      case .recovering: return "自动恢复中"
      case .failed: return "需要处理"
      }
    }

    var symbol: String {
      switch self {
      case .idle: return "pause.circle.fill"
      case .starting: return "ellipsis.circle.fill"
      case .listening: return "dot.radiowaves.left.and.right"
      case .recovering: return "arrow.trianglehead.2.clockwise.rotate.90.circle.fill"
      case .failed: return "exclamationmark.triangle.fill"
      }
    }
  }

  @Published private(set) var groups: [String]
  @Published var workspaceSelection: WorkspaceSelection
  @Published var groupDraft = ""
  @Published private(set) var messages: [MessageEvent] = []
  @Published private(set) var messageContextFocus: MessageContextFocus?
  @Published private(set) var listenerState: ListenerState = .idle
  @Published private(set) var doctorReport: DoctorReport?
  @Published private(set) var notificationLatestRowID: Int64?
  @Published private(set) var notificationHealth: NotificationMonitorHealth?
  @Published private(set) var historyDiagnostic: HistoryDiagnostic?
  @Published private(set) var activityText = "添加群聊后即可开始"
  @Published private(set) var messageStoreCapabilities: MessageStoreCapabilities?
  @Published private(set) var messageStoreError: String?
  @Published private(set) var rangeStatistics: MessageRangeStatistics?
  @Published private(set) var flowAnalytics: MessageFlowAnalytics?
  @Published private(set) var previousFlowAnalytics: MessageFlowAnalytics?
  @Published private(set) var managementMetrics: MessageManagementMetrics?
  @Published private(set) var reviewCursors: [String: ReviewCursor] = [:]
  @Published private(set) var isLoadingMessages = false
  @Published private(set) var hasMoreMessages = false
  @Published private(set) var automationStatus: AutomationEventBroadcasterStatus?
  @Published private(set) var automationError: String?
  @Published var automationEnabled = false
  @Published private(set) var workspaceStoreCapabilities: WorkspaceStoreCapabilities?
  @Published private(set) var workspaceStoreError: String?
  @Published private(set) var providerConfigurations: [AIProviderConfiguration] = []
  @Published private(set) var defaultProviderID: String?
  @Published private(set) var providerConnectionTests: [
    String: AIProviderConnectionTestResult
  ] = [:]
  @Published private(set) var testingProviderIDs: Set<String> = []
  @Published private(set) var messageRules: [MessageRule] = []
  @Published private(set) var analysisJobs: [AIAnalysisJob] = []
  @Published private(set) var analysisRanges: [String: FrozenMessageRange] = [:]
  @Published private(set) var analysisResults: [StoredAIAnalysisResult] = []
  @Published private(set) var workspaceAlerts: [WorkspaceAlert] = []
  @Published private(set) var crossGroupAddressIncidents: [CrossGroupAddressIncident] = []
  @Published private(set) var alertSourceMessages: [String: MessageEvent] = [:]
  @Published var memeAddressDraft = "" {
    didSet { scheduleMemeMentionSummaryRefresh() }
  }
  @Published private(set) var memeSelectedChain: GMGNChain? {
    didSet { scheduleMemeMentionSummaryRefresh() }
  }
  @Published private(set) var memeChainCandidates: [DexScreenerChainCandidate] = []
  @Published private(set) var memeChainDetectionMessage: String?
  @Published private(set) var isDetectingMemeChain = false
  @Published private(set) var memeTokenReport: GMGNTokenReport?
  @Published private(set) var memeMentionSummary: CryptoAddressMentionSummary?
  @Published private(set) var memeMentionSummaryError: String?
  @Published private(set) var isLoadingMemeMentionSummary = false
  @Published private(set) var memeQueryError: String?
  @Published private(set) var isQueryingMeme = false
  @Published private(set) var caWatchPoolConfiguration = CAWatchPoolConfiguration()
  @Published private(set) var caWatchPoolItems: [CAWatchPoolItem] = []
  @Published private(set) var removedCAWatchPoolItems: [CAWatchPoolItem] = []
  @Published private(set) var caSignalEnrichments: [String: CASignalEnrichment] = [:]
  @Published private(set) var isRefreshingCAWatchPool = false
  @Published private(set) var caWatchPoolLastRefreshAt: Date?
  @Published private(set) var caWatchPoolNextRefreshAt: Date?
  @Published private(set) var caWatchPoolLastRefreshSucceededCount = 0
  @Published private(set) var caWatchPoolLastRefreshFailedCount = 0
  @Published private(set) var caWatchPoolError: String?
  @Published private(set) var marketTrendingTokens: [GMGNTrendingToken] = []
  @Published private(set) var isLoadingMarketTrends = false
  @Published private(set) var marketTrendingLastRefreshAt: Date?
  @Published private(set) var marketTrendingError: String?
  @Published private(set) var tradeAutomationConfiguration = TradeAutomationConfiguration()
  @Published private(set) var tradeAutomationRules: [TradeAutomationRule] = []
  @Published private(set) var tradeIntents: [TradeIntent] = []
  @Published private(set) var tradeAutomationMetrics = TradeAutomationMetrics()
  @Published private(set) var tradeSimulationResults: [TradeAutomationSimulationResult] = []
  @Published private(set) var tradeSimulationLastRunAt: Date?
  @Published private(set) var gmgnTradeConfigurationState: GMGNTradeConfigurationState?
  @Published private(set) var gmgnPortfolioInfo: GMGNPortfolioInfoSnapshot?
  @Published private(set) var isRefreshingGMGNPortfolio = false
  @Published private(set) var gmgnPortfolioError: String?
  @Published private(set) var tradeAutomationError: String?
  @Published var manualBuyRequest: ManualBuyContext?
  @Published var manualSellRequest: ManualSellContext?
  @Published private(set) var isRefreshingTradeAutomation = false
  @Published private(set) var isUpdatingAlerts = false
  @Published private(set) var unacknowledgedAlertCount = 0
  @Published private(set) var unacknowledgedAlertCountIsCapped = false
  @Published var selectedAnalysisID: String?
  @Published private(set) var selectedAnalysisSourceMessages: [String: MessageEvent] = [:]
  @Published private(set) var selectedAnalysisSourceRevision = 0
  @Published private(set) var isProcessingAnalysisQueue = false
  @Published private(set) var capturedEventIDs: Set<String> = []
  @Published private(set) var suppressedEventIDs: Set<String> = []
  @Published private(set) var capturedTotalCount = 0
  @Published private(set) var soundConfiguration = NotificationSoundConfiguration()
  @Published private(set) var soundStatusText: String?
  @Published private(set) var isSpeechAPIKeyConfigured = false
  @Published var searchText = ""
  @Published var timePreset: MessageTimePreset = .last30Minutes
  @Published var customRangeStart = Calendar.current.startOfDay(for: Date())
  @Published var customRangeEnd = Date()
  @Published var includeExisting = false
  @Published var redactsGroupNames = false {
    didSet {
      UserDefaults.standard.set(
        redactsGroupNames,
        forKey: "wxfomo.privacy.redact-group-names"
      )
    }
  }
  @Published var includeKeywords = "" {
    didSet {
      UserDefaults.standard.set(includeKeywords, forKey: "wxfomo.filter.include")
      scheduleMessageReload()
    }
  }
  @Published var excludeKeywords = "" {
    didSet {
      UserDefaults.standard.set(excludeKeywords, forKey: "wxfomo.filter.exclude")
      scheduleMessageReload()
    }
  }
  @Published var captureKeywords = "" {
    didSet {
      UserDefaults.standard.set(captureKeywords, forKey: "wxfomo.capture.keywords")
      scheduleMessageReload()
    }
  }
  @Published var onlyMentions = false {
    didSet {
      UserDefaults.standard.set(onlyMentions, forKey: "wxfomo.filter.mentions")
      scheduleMessageReload()
    }
  }
  @Published var onlyKnownSenders = false {
    didSet {
      UserDefaults.standard.set(onlyKnownSenders, forKey: "wxfomo.filter.knownSenders")
      scheduleMessageReload()
    }
  }
  @Published var kindFilter: KindFilter = .all {
    didSet {
      UserDefaults.standard.set(kindFilter.rawValue, forKey: "wxfomo.filter.kind")
      scheduleMessageReload()
    }
  }
  @Published var addressFilter: AddressFilter = .all {
    didSet {
      UserDefaults.standard.set(addressFilter.rawValue, forKey: "wxfomo.filter.address")
    }
  }
  @Published private(set) var focusedAddress: CryptoAddressMatch?

  private var monitorTask: Task<Void, Never>?
  private var messageLoadTask: Task<Void, Never>?
  private var analysisRunnerTask: Task<Void, Never>?
  private var analysisStatusRefreshTask: Task<Void, Never>?
  private var loadedAnalysisSourceAnalysisID: String?
  private var addressBackfillTask: Task<Void, Never>?
  private var memeQueryTask: Task<Void, Never>?
  private var memeChainDetectionTask: Task<Void, Never>?
  private var memeMentionSummaryTask: Task<Void, Never>?
  private var caWatchPoolMonitorTask: Task<Void, Never>?
  private var caWatchPoolDebounceTask: Task<Void, Never>?
  private var marketTrendingTask: Task<Void, Never>?
  private var marketTrendingRequestKey: String?
  private var standaloneCAEnrichmentTasks: [String: Task<Void, Never>] = [:]
  private var tradeAutomationTasks: [String: Task<Void, Never>] = [:]
  private let messageStore: MessageStore?
  private let workspaceStore: WorkspaceStore?
  private let credentialStore = FileConfigurationCenterStore()
  private let gmgnClient = GMGNCLIClient()
  private let gmgnTradeClient = GMGNTradeClient()
  private let dexScreenerChainResolver = DexScreenerChainResolver()
  private var memeChainSelectionAddress: String?
  private var analysisRunner: AnalysisJobRunner?
  private var nextPageCursor: MessagePageCursor?
  private var automationBroadcaster: AutomationEventBroadcaster?
  private let soundController = NotificationSoundController()
  private var soundSuppressedUntil = Date.distantPast
  private var knownAnalysisResultIDs: Set<String> = []
  private var addressMatchesCache: [String: [CryptoAddressMatch]] = [:]
  private var webLinksCache: [String: [WebLinkMatch]] = [:]
  private var latestCASignalSnapshotIndex: [String: (updatedAt: Date, snapshot: CATokenMarketSnapshot)] = [:]
  private var didSeedAnalysisSoundBaseline = false
  private var lastNotificationHealthPublishedAt = Date.distantPast
  private var captureTagID: String?
  private var suppressedTagID: String?
  private let defaultsKey = "wxfomo.monitoredGroups"
  private let soundConfigurationDefaultsKey = "wxfomo.sound.configuration.v1"
  private let gmgnPortfolioDefaultsKey = "wxfomo.gmgn.portfolio.last-success.v1"
  private let messagePageSize = 500

  init() {
    let openedMessageStore: MessageStore?
    let openingError: String?
    do {
      openedMessageStore = try MessageStore()
      openingError = nil
    } catch {
      openedMessageStore = nil
      openingError = error.localizedDescription
    }
    messageStore = openedMessageStore
    messageStoreCapabilities = openedMessageStore?.capabilities
    messageStoreError = openingError

    let openedWorkspaceStore: WorkspaceStore?
    let workspaceOpeningError: String?
    do {
      openedWorkspaceStore = try WorkspaceStore()
      workspaceOpeningError = nil
    } catch {
      openedWorkspaceStore = nil
      workspaceOpeningError = error.localizedDescription
    }
    workspaceStore = openedWorkspaceStore
    workspaceStoreCapabilities = openedWorkspaceStore?.capabilities
    workspaceStoreError = workspaceOpeningError

    if let data = UserDefaults.standard.data(forKey: soundConfigurationDefaultsKey),
      let savedSoundConfiguration = try? JSONDecoder().decode(
        NotificationSoundConfiguration.self,
        from: data
      )
    {
      let migrated = savedSoundConfiguration.migratedForSpeechAnnouncements
      soundConfiguration = migrated
      if migrated != savedSoundConfiguration,
        let migratedData = try? JSONEncoder().encode(migrated)
      {
        UserDefaults.standard.set(migratedData, forKey: soundConfigurationDefaultsKey)
      }
    }
    if let data = UserDefaults.standard.data(forKey: gmgnPortfolioDefaultsKey),
      let savedPortfolio = try? JSONDecoder().decode(GMGNPortfolioInfoSnapshot.self, from: data)
    {
      gmgnPortfolioInfo = savedPortfolio
    }
    let saved = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    groups = saved
    activityText = saved.isEmpty ? "添加群聊后即可开始" : "已就绪，可开始监听"
    workspaceSelection = .inbox
    do {
      if credentialStore.configurationFileExists {
        soundConfiguration.speech = try credentialStore.speechConfiguration()
      } else {
        try credentialStore.storeSpeechConfiguration(soundConfiguration.speech)
      }
    } catch {
      soundStatusText = error.localizedDescription
    }
    isSpeechAPIKeyConfigured = (try? credentialStore.speechAPIKey()) != nil
    includeKeywords = UserDefaults.standard.string(forKey: "wxfomo.filter.include") ?? ""
    excludeKeywords = UserDefaults.standard.string(forKey: "wxfomo.filter.exclude") ?? ""
    captureKeywords = UserDefaults.standard.string(forKey: "wxfomo.capture.keywords") ?? ""
    onlyMentions = UserDefaults.standard.bool(forKey: "wxfomo.filter.mentions")
    onlyKnownSenders = UserDefaults.standard.bool(forKey: "wxfomo.filter.knownSenders")
    automationEnabled = UserDefaults.standard.bool(forKey: "wxfomo.automation.enabled")
    redactsGroupNames = UserDefaults.standard.bool(
      forKey: "wxfomo.privacy.redact-group-names"
    )
    if let rawKind = UserDefaults.standard.string(forKey: "wxfomo.filter.kind"),
      let savedKind = KindFilter(rawValue: rawKind)
    {
      kindFilter = savedKind
    }
    if let rawAddress = UserDefaults.standard.string(forKey: "wxfomo.filter.address"),
      let savedAddress = AddressFilter(rawValue: rawAddress)
    {
      addressFilter = savedAddress
    }
    refreshStatus()
    scheduleMessageReload()
    addressBackfillTask = Task { [weak self] in
      guard let self else { return }
      await reloadWorkspace()
      await loadCAWatchPool()
      await loadTradeAutomation()
      await backfillRecentCryptoAddressMentions()
    }
    if let openedMessageStore, let openedWorkspaceStore {
      analysisRunner = try? AnalysisJobRunner(
        messageStore: openedMessageStore,
        workspaceStore: openedWorkspaceStore
      )
      startAnalysisRunner()
    }
    if automationEnabled { startAutomation() }
  }

  deinit {
    monitorTask?.cancel()
    messageLoadTask?.cancel()
    addressBackfillTask?.cancel()
    memeQueryTask?.cancel()
    memeChainDetectionTask?.cancel()
    memeMentionSummaryTask?.cancel()
    caWatchPoolMonitorTask?.cancel()
    caWatchPoolDebounceTask?.cancel()
    marketTrendingTask?.cancel()
    standaloneCAEnrichmentTasks.values.forEach { $0.cancel() }
    tradeAutomationTasks.values.forEach { $0.cancel() }
    analysisStatusRefreshTask?.cancel()
    analysisRunnerTask?.cancel()
    if let analysisRunner {
      Task { await analysisRunner.stop() }
    }
  }

  var isListening: Bool {
    switch listenerState {
    case .starting, .listening, .recovering:
      return true
    case .idle, .failed:
      return false
    }
  }

  var knownSoundSenderNames: [String] {
    Array(
      Set(
        messages.compactMap { event in
          event.senderDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
      )
    ).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  var isSoundTemporarilyMuted: Bool {
    soundConfiguration.mutedUntil.map { $0 > Date() } ?? false
  }

  var visibleMessages: [MessageEvent] {
    if let focus = messageContextFocus {
      return messages.filter { $0.group == focus.group }
    }
    return messages.filter { event in
      let matchesGroup: Bool
      switch workspaceSelection {
      case .inbox:
        matchesGroup = !suppressedEventIDs.contains(event.eventID)
      case .captured:
        matchesGroup = isCaptured(event)
      case .group(let group):
        matchesGroup = event.group == group && !suppressedEventIDs.contains(event.eventID)
      case .analyses, .alerts, .meme, .market, .rules, .trading, .automations, .sounds, .providers,
        .diagnostics:
        matchesGroup = false
      }
      guard matchesGroup,
        matchesReviewCutoff(event),
        matchesConfiguredFilters(event),
        matchesAddressFilters(event)
      else {
        return false
      }
      // Search membership already comes from MessageStore. Applying a second
      // substring search here would disagree with SQLite FTS token semantics.
      return true
    }
  }

  var selectedTitle: String {
    switch workspaceSelection {
    case .inbox: return "消息收件箱"
    case .captured: return "重点捕捉"
    case .group(let group): return displayGroupName(group)
    case .analyses: return "分析记录"
    case .alerts: return "提醒中心"
    case .meme: return "Meme 观察"
    case .market: return "市场趋势"
    case .rules: return "监控规则"
    case .trading: return "交易工作台"
    case .automations: return "自动化交易"
    case .sounds: return "声音与提醒"
    case .providers: return "配置中心"
    case .diagnostics: return "运行诊断"
    }
  }

  var configurationCenterPath: String {
    credentialStore.fileURL.path
  }

  func isProviderAPIKeyConfigured(_ configuration: AIProviderConfiguration) -> Bool {
    (try? credentialStore.apiKey(for: configuration)) != nil
  }

  var displayedActivityText: String {
    guard redactsGroupNames else { return activityText }
    return groups
      .filter { !$0.isEmpty }
      .sorted { $0.count > $1.count }
      .reduce(activityText) { text, group in
        text.replacingOccurrences(of: group, with: "***")
      }
  }

  func displayGroupName(_ group: String) -> String {
    redactsGroupNames ? "***" : group
  }

  var capturedCount: Int {
    capturedTotalCount
  }

  var selectedAnalysisResult: StoredAIAnalysisResult? {
    guard let selectedAnalysisID else { return nil }
    return analysisResults.first { $0.result.analysisID == selectedAnalysisID }
  }

  var pendingAnalysisJobCount: Int {
    analysisJobs.filter { !$0.state.isTerminal }.count
  }

  var unacknowledgedAlertCountLabel: String {
    unacknowledgedAlertCountIsCapped ? "\(unacknowledgedAlertCount)+" : "\(unacknowledgedAlertCount)"
  }

  func sourceMessage(forEventID eventID: String) -> MessageEvent? {
    alertSourceMessages[eventID] ?? messages.first { $0.eventID == eventID }
  }

  func sourceMessages(for alert: WorkspaceAlert) -> [MessageEvent] {
    alert.sourceEventIDs.compactMap { sourceMessage(forEventID: $0) }
  }

  func crossGroupAddressIncident(forAlertID alertID: String) -> CrossGroupAddressIncident? {
    crossGroupAddressIncidents.first { $0.alertID == alertID }
  }

  func openMemeMode(for incident: CrossGroupAddressIncident) {
    prepareMemeMode(
      address: incident.normalizedAddress,
      suggestedChain: caTokenSnapshot(for: incident)?.chain
        ?? incident.network.flatMap { gmgnChain(for: $0) }
        ?? (incident.family == .solana ? .sol : nil)
    )
  }

  func openMemeMode(for match: CryptoAddressMatch) {
    prepareMemeMode(
      address: match.normalizedAddress,
      suggestedChain: caWatchPoolItem(for: match)?.chain
        ?? gmgnChain(for: match.network)
        ?? (match.family == .solana ? .sol : nil)
    )
  }

  func openMemeMode(for match: CryptoAddressMatch, sourceMessage: MessageEvent) {
    let suggestedChain = caTokenSnapshot(eventID: sourceMessage.eventID, match: match)?.chain
      ?? gmgnChain(for: match.network)
      ?? (match.family == .solana ? .sol : nil)
    prepareMemeMode(address: match.normalizedAddress, suggestedChain: suggestedChain)
  }

  func openMemeMode(for address: AIAnalysisCryptoAddress) {
    prepareMemeMode(
      address: address.normalizedAddress,
      suggestedChain: caTokenSnapshot(for: address)?.chain
        ?? (address.network == .solana ? .sol : nil)
    )
  }

  func openMemeMode(for item: CAWatchPoolItem) {
    prepareMemeMode(address: item.normalizedAddress, suggestedChain: item.chain)
  }

  func openMemeMode(for token: GMGNTrendingToken) {
    prepareMemeMode(address: token.address, suggestedChain: token.chain)
  }

  func presentManualBuy(rawInput: String, mode: ManualBuyMode) async throws {
    let context = try await resolveManualBuyContext(rawInput: rawInput, mode: mode)
    manualBuyRequest = context
  }

  func presentManualBuy(context: ManualBuyContext) {
    manualBuyRequest = context
  }

  func resolveManualBuyContext(
    rawInput: String,
    mode: ManualBuyMode
  ) async throws -> ManualBuyContext {
    let matches = CryptoAddressDetector.matches(in: rawInput)
    guard matches.count == 1, let match = matches.first else {
      throw GMGNCLIError.commandFailed(
        matches.isEmpty ? "请输入一个完整 CA 或包含 CA 的链接。" : "一次只能提交一个 CA。"
      )
    }
    let cachedSnapshot = cachedManualBuySnapshot(for: match)
    var detectedToken = cachedSnapshot
    var chain = cachedSnapshot?.chain
      ?? gmgnChain(for: match.network)
      ?? (match.family == .solana ? .sol : nil)
    var candidates: [DexScreenerChainCandidate] = []
    var detectionMessage: String?
    var usesDexScreenerFallback = false

    if let chain {
      if chain == .robinhood, cachedSnapshot != nil {
        detectionMessage = "已从本地 CA 缓存识别为 Robinhood"
      } else if chain == .robinhood {
        detectionMessage = "已根据输入中的网络信息识别为 Robinhood"
      } else if cachedSnapshot != nil {
        detectionMessage = "已从本地 CA 缓存识别为 \(chain.localizedTitle)"
      } else if match.family == .solana {
        detectionMessage = "已根据地址格式识别为 Solana"
      } else {
        detectionMessage = "已根据输入中的网络信息识别为 \(chain.localizedTitle)"
      }
    } else if match.family == .evm {
      do {
        let gmgnTokens = try await gmgnClient.identifyEVMToken(address: match.normalizedAddress)
          .sorted { ($0.liquidityUSD ?? 0) > ($1.liquidityUSD ?? 0) }
        if gmgnTokens.count == 1, let token = gmgnTokens.first {
          detectedToken = token
          chain = token.chain
          candidates = [gmgnCandidate(for: token)]
          detectionMessage = token.chain == .robinhood
            ? "GMGN 识别为 Robinhood"
            : "GMGN 识别为 \(token.chain.localizedTitle)"
        } else if !gmgnTokens.isEmpty {
          candidates = gmgnTokens.map(gmgnCandidate(for:))
          detectionMessage = "GMGN 在多个网络返回有效代币，请先选择网络"
        } else {
          let fallback = await manualBuyDexScreenerResolution(address: match.normalizedAddress)
          chain = fallback.chain
          candidates = fallback.candidates
          detectionMessage = fallback.message
          usesDexScreenerFallback = true
        }
      } catch {
        let fallback = await manualBuyDexScreenerResolution(address: match.normalizedAddress)
        chain = fallback.chain
        candidates = fallback.candidates
        detectionMessage = fallback.message
        usesDexScreenerFallback = true
      }
    }

    if detectedToken == nil, let chain {
      if usesDexScreenerFallback {
        detectedToken = try? await dexScreenerChainResolver.tokenSnapshot(
          chain: chain,
          address: match.normalizedAddress
        )
      } else {
        detectedToken = try? await gmgnClient.tokenSnapshot(
          chain: chain,
          address: match.normalizedAddress
        )
        if detectedToken == nil {
          detectedToken = try? await dexScreenerChainResolver.tokenSnapshot(
            chain: chain,
            address: match.normalizedAddress
          )
        }
      }
    }
    return ManualBuyContext(
      address: match.normalizedAddress,
      suggestedChain: chain,
      symbol: detectedToken?.symbol,
      name: detectedToken?.name,
      tokenDecimals: detectedToken?.decimals,
      logoURL: detectedToken?.logoURL,
      marketCapUSD: detectedToken?.marketCapUSD,
      liquidityUSD: detectedToken?.liquidityUSD,
      sourceTitle: "CA 输入",
      sourceGroups: ["CA 输入"],
      mode: mode,
      chainCandidates: candidates,
      chainDetectionMessage: detectionMessage
    )
  }

  private func cachedManualBuySnapshot(for match: CryptoAddressMatch) -> GMGNTokenSnapshot? {
    if let report = memeTokenReport,
      sameAddress(report.token.address, match.normalizedAddress, family: match.family)
    {
      return report.token
    }
    if let item = caWatchPoolItem(for: match) {
      guard let snapshot = item.currentSnapshot ?? item.entrySnapshot else { return nil }
      return GMGNTokenSnapshot(
        chain: snapshot.chain,
        address: snapshot.address,
        symbol: snapshot.symbol,
        name: snapshot.name,
        priceUSD: snapshot.priceUSD,
        marketCapUSD: snapshot.marketCapUSD,
        liquidityUSD: snapshot.liquidityUSD,
        volume1hUSD: nil,
        priceChange1hPercent: nil,
        holderCount: nil,
        smartWalletCount: nil,
        renownedWalletCount: nil,
        logoURL: snapshot.logoURL,
        website: nil,
        twitterUsername: nil,
        gmgnURL: nil,
        geckoTerminalURL: nil
      )
    }
    return nil
  }

  private func sameAddress(
    _ lhs: String,
    _ rhs: String,
    family: CryptoAddressFamily
  ) -> Bool {
    family == .evm
      ? lhs.caseInsensitiveCompare(rhs) == .orderedSame
      : lhs == rhs
  }

  private func gmgnCandidate(for token: GMGNTokenSnapshot) -> DexScreenerChainCandidate {
    DexScreenerChainCandidate(
      chain: token.chain,
      pairCount: 1,
      maxLiquidityUSD: token.liquidityUSD,
      maxVolume24hUSD: nil
    )
  }

  private func manualBuyDexScreenerResolution(
    address: String
  ) async -> (
    chain: GMGNChain?,
    candidates: [DexScreenerChainCandidate],
    message: String
  ) {
    do {
      let resolution = try await resolveEVMChain(address: address)
      let chain = resolution.selectedChain
      if chain == .robinhood {
        return (
          chain,
          resolution.candidates,
          resolution.source == .persistentCache
            ? "GMGN 未命中，已从本地链缓存识别为 Robinhood"
            : "GMGN 未命中，DexScreener 池数据识别为 Robinhood"
        )
      }
      if let chain {
        return (
          chain,
          resolution.candidates,
          resolution.source == .persistentCache
            ? "GMGN 未命中，已从本地链缓存读取 \(chain.localizedTitle)"
            : "GMGN 未命中，DexScreener 池数据识别为 \(chain.localizedTitle)"
        )
      }
      return (
        nil,
        resolution.candidates,
        resolution.candidates.isEmpty
          ? "GMGN 与 DexScreener 均未识别，请手动选择网络"
          : "GMGN 未唯一识别，多个 DexScreener 网络信号接近，请先选择网络"
      )
    } catch {
      return (nil, [], "GMGN 与 DexScreener 均未完成识别，请手动选择网络")
    }
  }

  private func resolveEVMChain(
    address: String,
    now: Date = Date()
  ) async throws -> DexScreenerChainResolution {
    if let workspaceStore,
      let cached = try? await workspaceStore.dexScreenerChainResolution(
        address: address,
        now: now
      )
    {
      return cached
    }

    let resolution = try await dexScreenerChainResolver.resolve(address: address, now: now)
    if resolution.selectedChain != nil, let workspaceStore {
      _ = try? await workspaceStore.saveDexScreenerChainResolution(resolution, now: now)
    }
    return resolution
  }

  func presentManualBuy(
    for match: CryptoAddressMatch,
    sourceMessage: MessageEvent? = nil
  ) {
    let snapshot = sourceMessage.flatMap {
      caTokenSnapshot(eventID: $0.eventID, match: match)
    } ?? caWatchPoolItem(for: match)?.currentSnapshot
    let chain = snapshot?.chain ?? gmgnChain(for: match.network)
      ?? (match.family == .solana ? .sol : nil)
    let sourceTitle = sourceMessage.map { "消息 · \(displayGroupName($0.group))" }
    manualBuyRequest = ManualBuyContext(
      address: match.normalizedAddress,
      suggestedChain: chain,
      symbol: snapshot?.symbol,
      name: snapshot?.name,
      logoURL: snapshot?.logoURL,
      marketCapUSD: snapshot?.marketCapUSD,
      liquidityUSD: snapshot?.liquidityUSD,
      sourceTitle: sourceTitle,
      mentionSummary: nil,
      sourceEventIDs: sourceMessage.map { [$0.eventID] } ?? [],
      sourceGroups: sourceMessage.map { [$0.group] } ?? []
    )
  }

  func presentManualBuy(for incident: CrossGroupAddressIncident) {
    let snapshot = caTokenSnapshot(for: incident) ?? caTriggerSnapshot(for: incident)
    let chain = snapshot?.chain
      ?? incident.network.flatMap { gmgnChain(for: $0) }
      ?? (incident.family == .solana ? .sol : nil)
    manualBuyRequest = ManualBuyContext(
      address: incident.normalizedAddress,
      suggestedChain: chain,
      symbol: snapshot?.symbol,
      name: snapshot?.name,
      logoURL: snapshot?.logoURL,
      marketCapUSD: snapshot?.marketCapUSD,
      liquidityUSD: snapshot?.liquidityUSD,
      sourceTitle: "跨群 CA · \(incident.groupCount) 个群",
      mentionSummary: "\(incident.mentionCount) 次提及",
      sourceEventIDs: incident.sourceEventIDs,
      sourceGroups: incident.groupNames
    )
  }

  func presentManualBuy(for item: CAWatchPoolItem) {
    let snapshot = item.currentSnapshot ?? item.entrySnapshot
    manualBuyRequest = ManualBuyContext(
      address: item.normalizedAddress,
      suggestedChain: item.chain ?? snapshot?.chain,
      symbol: snapshot?.symbol,
      name: snapshot?.name,
      logoURL: snapshot?.logoURL,
      marketCapUSD: snapshot?.marketCapUSD,
      liquidityUSD: snapshot?.liquidityUSD,
      sourceTitle: "Meme 观察 · \(item.groupNames.count) 个群",
      mentionSummary: "\(item.mentionCount) 次提及",
      sourceGroups: item.groupNames
    )
  }

  func presentManualBuy(for report: GMGNTokenReport) {
    manualBuyRequest = ManualBuyContext(
      address: report.token.address,
      suggestedChain: report.token.chain,
      symbol: report.token.symbol,
      name: report.token.name,
      logoURL: report.token.logoURL,
      marketCapUSD: report.token.marketCapUSD,
      liquidityUSD: report.token.liquidityUSD,
      sourceTitle: "Meme 分析",
      mentionSummary: memeMentionSummary.map {
        "\($0.groupCount) 个群 · \($0.mentionCount) 次提及"
      },
      sourceGroups: ["Meme 分析"]
    )
  }

  func presentManualBuy(for address: AIAnalysisCryptoAddress) {
    let snapshot = caTokenSnapshot(for: address)
    let chain = snapshot?.chain
      ?? (address.network == .solana ? .sol : nil)
    manualBuyRequest = ManualBuyContext(
      address: address.normalizedAddress,
      suggestedChain: chain,
      symbol: snapshot?.symbol,
      name: snapshot?.name,
      logoURL: snapshot?.logoURL,
      marketCapUSD: snapshot?.marketCapUSD,
      liquidityUSD: snapshot?.liquidityUSD,
      sourceTitle: "AI 分析 · \(address.occurrenceCount) 次出现",
      mentionSummary: nil,
      sourceEventIDs: address.sourceMessageIDs,
      sourceGroups: ["AI 分析"]
    )
  }

  func presentManualBuy(for intent: TradeIntent) {
    manualBuyRequest = ManualBuyContext(
      address: intent.tokenAddress,
      suggestedChain: intent.chain,
      intentID: intent.resolvedSide == .buy
        && [.eligible, .awaitingConfirmation, .quoted].contains(intent.state)
        ? intent.id : nil,
      suggestedAmountNative: intent.resolvedSide == .buy ? intent.inputAmountNative : nil,
      suggestedSlippagePercent: intent.quote?.requestedSlippagePercent,
      symbol: intent.tokenSymbol,
      name: intent.tokenName,
      logoURL: intent.tokenLogoURL,
      marketCapUSD: intent.marketSnapshot?.marketCapUSD,
      liquidityUSD: intent.marketSnapshot?.liquidityUSD,
      sourceTitle: intent.resolvedSide == .buy
        ? "自动化意图 · \(intent.distinctGroupCount) 个群" : "卖出记录 · 再次买入",
      mentionSummary: "\(intent.mentionCount) 次提及",
      sourceEventIDs: intent.sourceEventIDs,
      sourceGroups: intent.sourceGroups
    )
  }

  func presentManualSell(for intent: TradeIntent, mode: ManualBuyMode = .quick) {
    guard intent.resolvedSide == .buy, intent.state == .confirmed,
      let chain = intent.chain
    else {
      tradeAutomationError = "只有已确认的买入记录可以发起卖出。"
      return
    }
    manualSellRequest = ManualSellContext(
      sourceIntentID: intent.id,
      chain: chain,
      tokenAddress: intent.tokenAddress,
      tokenSymbol: intent.tokenSymbol,
      tokenName: intent.tokenName,
      tokenLogoURL: intent.tokenLogoURL,
      walletAddress: intent.quote?.walletAddress,
      suggestedSlippagePercent: intent.quote?.requestedSlippagePercent ?? 12,
      mode: mode
    )
  }

  func refreshGMGNTradeConfiguration() {
    Task { [weak self] in
      guard let self else { return }
      self.gmgnTradeConfigurationState = await self.gmgnTradeClient.configurationState()
    }
  }

  func refreshGMGNPortfolio() {
    guard !isRefreshingGMGNPortfolio else { return }
    isRefreshingGMGNPortfolio = true
    gmgnPortfolioError = nil
    Task { [weak self] in
      guard let self else { return }
      do {
        let snapshot = try await self.gmgnTradeClient.portfolioInfo(forceRefresh: true)
        self.storeGMGNPortfolio(snapshot)
        self.gmgnPortfolioError = nil
      } catch {
        self.gmgnPortfolioError = self.gmgnPortfolioErrorMessage(error)
      }
      self.isRefreshingGMGNPortfolio = false
    }
  }

  func walletAddress(for chain: GMGNChain?) -> String? {
    guard let chain else { return nil }
    if let linked = linkedWalletAddress(for: chain) { return linked }
    guard let fallback = tradeAutomationConfiguration.walletAddress,
      walletAddress(fallback, matches: chain)
    else { return nil }
    return fallback
  }

  private func resolvedWalletAddress(for chain: GMGNChain) async -> String? {
    if let linked = linkedWalletAddress(for: chain) { return linked }
    do {
      let snapshot = try await gmgnTradeClient.portfolioInfo()
      storeGMGNPortfolio(snapshot)
      gmgnPortfolioError = nil
      if let linked = linkedWalletAddress(for: chain) { return linked }
    } catch {
      gmgnPortfolioError = gmgnPortfolioErrorMessage(error)
    }
    return walletAddress(for: chain)
  }

  private func linkedWalletAddress(for chain: GMGNChain) -> String? {
    guard let linked = gmgnPortfolioInfo?.wallets.first(where: {
      $0.chainID?.lowercased() == chain.rawValue
    })?.primaryAddress,
      walletAddress(linked, matches: chain)
    else { return nil }
    return linked
  }

  private func walletAddress(_ rawAddress: String, matches chain: GMGNChain) -> Bool {
    let address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    if chain == .sol {
      return address.range(
        of: #"^[1-9A-HJ-NP-Za-km-z]{32,44}$"#,
        options: .regularExpression
      ) != nil
    }
    return address.range(of: #"^0x[0-9A-Fa-f]{40}$"#, options: .regularExpression) != nil
  }

  private func storeGMGNPortfolio(_ snapshot: GMGNPortfolioInfoSnapshot) {
    gmgnPortfolioInfo = snapshot
    guard let data = try? JSONEncoder().encode(snapshot) else { return }
    UserDefaults.standard.set(data, forKey: gmgnPortfolioDefaultsKey)
  }

  private func gmgnPortfolioErrorMessage(_ error: Error) -> String {
    let base = error.localizedDescription
    guard gmgnPortfolioInfo != nil else { return base }
    switch error as? GMGNCLIError {
    case .timedOut, .networkUnavailable:
      return "\(base) 已保留上次成功读取的账户。"
    default:
      return base
    }
  }

  func quoteManualBuy(
    chain: GMGNChain,
    outputToken: String,
    amountNative: Double,
    slippagePercent: Int
  ) async throws -> GMGNTradeQuote {
    guard let wallet = await resolvedWalletAddress(for: chain),
      let inputToken = GMGNNativeAsset.address(for: chain),
      let amount = GMGNNativeAsset.smallestUnitAmount(amountNative, chain: chain)
    else {
      throw GMGNCLIError.notConfigured
    }
    return try await gmgnTradeClient.quote(
      GMGNTradeQuoteRequest(
        chain: chain,
        walletAddress: wallet,
        inputToken: inputToken,
        outputToken: outputToken,
        inputAmountSmallestUnit: amount,
        slippagePercent: slippagePercent
      )
    )
  }

  func prepareManualBuy(
    chain: GMGNChain,
    outputToken: String,
    amountNative: Double,
    slippagePercent: Int,
    skipRugAssessment: Bool = false
  ) async throws -> ManualBuyPreparation {
    async let inspection = inspectManualBuy(
      chain: chain,
      outputToken: outputToken,
      skipRugAssessment: skipRugAssessment
    )
    async let quote = quoteManualBuy(
      chain: chain,
      outputToken: outputToken,
      amountNative: amountNative,
      slippagePercent: slippagePercent
    )
    let (resolvedInspection, resolvedQuote) = try await (inspection, quote)
    return ManualBuyPreparation(
      report: resolvedInspection.report,
      quote: resolvedQuote,
      safety: resolvedInspection.safety
    )
  }

  func inspectManualBuy(
    chain: GMGNChain,
    outputToken: String,
    skipRugAssessment: Bool
  ) async throws -> ManualBuyInspection {
    let report = try await gmgnClient.tokenReport(
      chain: chain,
      address: outputToken,
      forceRefresh: true
    )
    let safety = skipRugAssessment
      ? GMGNTradeSafetyEvaluator.assessQuickBuy(
        security: report.security,
        securityError: report.securityError
      )
      : GMGNTradeSafetyEvaluator.assess(
        security: report.security,
        securityError: report.securityError
      )
    return ManualBuyInspection(report: report, safety: safety)
  }

  func prepareManualSell(
    context: ManualSellContext,
    percent: Int,
    slippagePercent: Int
  ) async throws -> ManualSellPreparation {
    let latestWallet = await resolvedWalletAddress(for: context.chain)
    let wallet = latestWallet ?? context.walletAddress.flatMap {
      walletAddress($0, matches: context.chain) ? $0 : nil
    }
    guard (1...100).contains(percent),
      let wallet,
      let outputToken = GMGNNativeAsset.address(for: context.chain)
    else {
      throw GMGNCLIError.notConfigured
    }

    async let reportRequest = gmgnClient.tokenReport(
      chain: context.chain,
      address: context.tokenAddress,
      forceRefresh: true
    )
    async let balanceRequest = gmgnTradeClient.tokenBalance(
      chain: context.chain,
      walletAddress: wallet,
      tokenAddress: context.tokenAddress
    )
    let (report, balance) = try await (reportRequest, balanceRequest)
    let storedDecimals = tradeIntents.first(where: { $0.id == context.sourceIntentID })?
      .executionReport?.outputTokenDecimals
    guard let decimals = report.token.decimals ?? storedDecimals,
      let amount = GMGNTokenAmount.smallestUnit(
        humanBalance: balance.balance,
        percent: percent,
        decimals: decimals
      )
    else {
      throw GMGNCLIError.commandFailed("该代币当前没有可卖余额，或无法取得代币精度。")
    }
    let quote = try await gmgnTradeClient.quote(
      GMGNTradeQuoteRequest(
        chain: context.chain,
        walletAddress: wallet,
        inputToken: context.tokenAddress,
        outputToken: outputToken,
        inputAmountSmallestUnit: amount,
        slippagePercent: slippagePercent
      )
    )
    return ManualSellPreparation(
      balance: balance,
      tokenDecimals: decimals,
      inputAmountSmallestUnit: amount,
      quote: quote
    )
  }

  func executeManualSell(
    context: ManualSellContext,
    percent: Int,
    slippagePercent: Int,
    antiMEV: Bool,
    preparation: ManualSellPreparation,
    authorization: ManualSellAuthorization
  ) async throws -> GMGNTradeOrderSnapshot {
    guard !tradeAutomationConfiguration.emergencyStopped else {
      throw GMGNCLIError.commandFailed("全局紧急停止已启用，不能提交真实交易。")
    }
    let latestWallet = await resolvedWalletAddress(for: context.chain)
    let wallet = latestWallet ?? context.walletAddress.flatMap {
      walletAddress($0, matches: context.chain) ? $0 : nil
    }
    guard (1...100).contains(percent),
      let wallet,
      let outputToken = GMGNNativeAsset.address(for: context.chain)
    else {
      throw GMGNCLIError.notConfigured
    }
    let quoteRequest = GMGNTradeQuoteRequest(
      chain: context.chain,
      walletAddress: wallet,
      inputToken: context.tokenAddress,
      outputToken: outputToken,
      inputAmountSmallestUnit: preparation.inputAmountSmallestUnit,
      slippagePercent: slippagePercent
    )
    guard preparation.quote.matches(quoteRequest) else {
      throw GMGNCLIError.commandFailed("卖出报价已过期或参数已变化，请重新获取报价。")
    }
    let balanceAge = Date().timeIntervalSince(preparation.balance.fetchedAt)
    guard balanceAge >= 0, balanceAge <= GMGNTradeQuote.maximumAge,
      walletAddress(preparation.balance.walletAddress, matches: context.chain),
      addressesEqual(preparation.balance.tokenAddress, context.tokenAddress, chain: context.chain),
      GMGNTokenAmount.smallestUnit(
        humanBalance: preparation.balance.balance,
        percent: percent,
        decimals: preparation.tokenDecimals
      ) == preparation.inputAmountSmallestUnit
    else {
      throw GMGNCLIError.commandFailed("代币余额已过期或卖出比例已变化，请重新准备交易。")
    }
    guard let workspaceStore else { throw GMGNCLIError.notConfigured }
    let unresolvedIntents = try await workspaceStore.tradeIntents(
      states: [.submitting, .pending],
      limit: 1_000
    )
    guard !unresolvedIntents.contains(where: {
      $0.chain == context.chain
        && addressesEqual($0.tokenAddress, context.tokenAddress, chain: context.chain)
    }) else {
      throw GMGNCLIError.commandFailed(
        "该 CA 已有未完成或结果待核对的交易，请先刷新交易记录。"
      )
    }

    let request = GMGNTradeSwapRequest(
      chain: context.chain,
      walletAddress: wallet,
      inputToken: context.tokenAddress,
      outputToken: outputToken,
      inputAmountSmallestUnit: preparation.inputAmountSmallestUnit,
      inputPercent: percent,
      slippagePercent: slippagePercent,
      antiMEV: antiMEV
    )
    let now = Date()
    let source = try await workspaceStore.tradeIntent(id: context.sourceIntentID)
    let inputAmountNative = sellHumanAmount(
      balance: preparation.balance.balance,
      percent: percent
    )
    var intent = TradeIntent(
      idempotencyKey: "manual-sell:\(UUID().uuidString)",
      ruleID: "manual-sell",
      side: .sell,
      state: .submitting,
      chain: context.chain,
      family: context.chain.addressFamily,
      tokenAddress: context.tokenAddress,
      tokenSymbol: context.tokenSymbol,
      tokenName: context.tokenName,
      tokenLogoURL: context.tokenLogoURL,
      sourceEventIDs: source?.sourceEventIDs ?? [],
      sourceGroups: ["手动卖出"],
      mentionCount: 1,
      distinctGroupCount: 1,
      marketSnapshot: source?.marketSnapshot,
      inputToken: context.tokenAddress,
      outputToken: outputToken,
      sellPercent: percent,
      parentIntentID: context.sourceIntentID,
      inputAmountNative: inputAmountNative,
      inputAmountSmallestUnit: preparation.inputAmountSmallestUnit,
      quote: preparation.quote,
      submittedAt: now,
      createdAt: now,
      updatedAt: now
    )
    _ = try await workspaceStore.insertTradeIntent(intent)
    await refreshTradeAutomationMetrics()
    let receipt = try await submitAndTrackManualSwap(
      request,
      intent: &intent,
      workspaceStore: workspaceStore
    )
    if receipt.isConfirmed {
      try? await refreshPortfolioAfterTrade()
    }
    return receipt
  }

  func executeManualBuy(
    chain: GMGNChain,
    outputToken: String,
    amountNative: Double,
    slippagePercent: Int,
    antiMEV: Bool,
    preparation: ManualBuyPreparation,
    context: ManualBuyContext,
    authorization: ManualBuyAuthorization,
    confirmedHighRisk: Bool
  ) async throws -> GMGNTradeOrderSnapshot {
    guard !tradeAutomationConfiguration.emergencyStopped else {
      throw GMGNCLIError.commandFailed("全局紧急停止已启用，不能提交真实交易。")
    }
    guard let wallet = await resolvedWalletAddress(for: chain),
      let inputToken = GMGNNativeAsset.address(for: chain),
      let amount = GMGNNativeAsset.smallestUnitAmount(amountNative, chain: chain)
    else {
      throw GMGNCLIError.notConfigured
    }
    let request = GMGNTradeSwapRequest(
      chain: chain,
      walletAddress: wallet,
      inputToken: inputToken,
      outputToken: outputToken,
      inputAmountSmallestUnit: amount,
      slippagePercent: slippagePercent,
      antiMEV: antiMEV
    )
    let quoteRequest = GMGNTradeQuoteRequest(
      chain: chain,
      walletAddress: wallet,
      inputToken: inputToken,
      outputToken: outputToken,
      inputAmountSmallestUnit: amount,
      slippagePercent: slippagePercent
    )
    let quote = preparation.quote
    guard quote.matches(quoteRequest) else {
      throw GMGNCLIError.commandFailed("报价已过期或与当前买入参数不一致，请重新获取报价。")
    }
    let reportAddressMatches = chain == .sol
      ? preparation.report.token.address == outputToken
      : preparation.report.token.address.caseInsensitiveCompare(outputToken) == .orderedSame
    guard preparation.report.token.chain == chain,
      reportAddressMatches,
      !preparation.report.isCached,
      Date().timeIntervalSince(preparation.report.fetchedAt) >= 0,
      Date().timeIntervalSince(preparation.report.fetchedAt) <= GMGNTradeQuote.maximumAge
    else {
      throw GMGNCLIError.commandFailed("安全检查已过期或与当前 CA 不一致，请重新准备交易。")
    }
    let currentSafety = authorization == .quickBuyButton
      ? GMGNTradeSafetyEvaluator.assessQuickBuy(
        security: preparation.report.security,
        securityError: preparation.report.securityError
      )
      : GMGNTradeSafetyEvaluator.assess(
        security: preparation.report.security,
        securityError: preparation.report.securityError
      )
    guard currentSafety.allowsStandardBuy else {
      throw GMGNCLIError.commandFailed(currentSafety.detail)
    }
    if authorization == .quickBuyButton, !currentSafety.allowsQuickBuy {
      throw GMGNCLIError.commandFailed("当前安全结果不允许快速买入，请切换普通模式复核。")
    }
    if currentSafety.requiresAdditionalConfirmation, !confirmedHighRisk {
      throw GMGNCLIError.commandFailed("高风险代币不能使用快速模式买入。")
    }
    guard let workspaceStore else {
      throw GMGNCLIError.notConfigured
    }
    let unresolvedIntents = try await workspaceStore.tradeIntents(
      states: [.submitting, .pending],
      limit: 1_000
    )
    let hasUnresolvedDuplicate = unresolvedIntents.contains { candidate in
      guard candidate.chain == chain else { return false }
      return chain == .sol
        ? candidate.tokenAddress == outputToken
        : candidate.tokenAddress.caseInsensitiveCompare(outputToken) == .orderedSame
    }
    guard !hasUnresolvedDuplicate else {
      throw GMGNCLIError.commandFailed(
        "该 CA 已有未完成或结果待核对的交易，请先刷新交易记录，避免重复买入。"
      )
    }

    let now = Date()
    var intent: TradeIntent
    if let existingID = context.intentID,
      let existing = try await workspaceStore.tradeIntent(id: existingID)
    {
      guard existing.state != .submitting, existing.state != .pending else {
        throw GMGNCLIError.commandFailed("该交易尚未到达终态，请先刷新订单状态，避免重复买入。")
      }
      intent = existing
      intent.side = .buy
      intent.chain = chain
      intent.family = chain.addressFamily
      intent.tokenAddress = outputToken
      intent.inputToken = inputToken
      intent.outputToken = outputToken
      intent.sellPercent = nil
      intent.parentIntentID = nil
      intent.inputAmountNative = amountNative
      intent.inputAmountSmallestUnit = amount
      intent.quote = quote
      intent.securitySnapshot = preparation.report.security
      intent.tokenSymbol = preparation.report.token.symbol.isEmpty
        ? intent.tokenSymbol : preparation.report.token.symbol
      intent.tokenName = preparation.report.token.name.isEmpty
        ? intent.tokenName : preparation.report.token.name
      intent.tokenLogoURL = preparation.report.token.logoURL ?? intent.tokenLogoURL
      intent.state = .submitting
      intent.submittedAt = now
      intent.confirmedAt = nil
      intent.rejectionReasons = []
      intent.failureReason = nil
      intent.updatedAt = now
      _ = try await workspaceStore.updateTradeIntent(intent)
    } else {
      let groups = context.sourceGroups.isEmpty ? [context.sourceTitle ?? "手动买入"] : context.sourceGroups
      let sourceEventIDs = context.sourceEventIDs
      let marketSnapshot: CATokenMarketSnapshot?
      let preparedToken = preparation.report.token
      if context.marketCapUSD != nil || context.liquidityUSD != nil
        || preparedToken.marketCapUSD != nil || preparedToken.liquidityUSD != nil
      {
        marketSnapshot = CATokenMarketSnapshot(
          chain: chain,
          address: outputToken,
          symbol: preparedToken.symbol.isEmpty ? (context.symbol ?? "") : preparedToken.symbol,
          name: preparedToken.name.isEmpty ? (context.name ?? "") : preparedToken.name,
          priceUSD: preparedToken.priceUSD,
          marketCapUSD: context.marketCapUSD ?? preparedToken.marketCapUSD,
          liquidityUSD: context.liquidityUSD ?? preparedToken.liquidityUSD,
          logoURL: preparedToken.logoURL ?? context.logoURL,
          capturedAt: now
        )
      } else {
        marketSnapshot = nil
      }
      intent = TradeIntent(
        idempotencyKey: "manual-buy:\(UUID().uuidString)",
        ruleID: "manual-buy",
        side: .buy,
        state: .submitting,
        chain: chain,
        family: chain.addressFamily,
        tokenAddress: outputToken,
        tokenSymbol: preparedToken.symbol.isEmpty ? context.symbol : preparedToken.symbol,
        tokenName: preparedToken.name.isEmpty ? context.name : preparedToken.name,
        tokenLogoURL: preparedToken.logoURL ?? context.logoURL,
        sourceEventIDs: sourceEventIDs,
        sourceGroups: groups,
        mentionCount: max(1, sourceEventIDs.count),
        distinctGroupCount: max(1, Set(groups).count),
        marketSnapshot: marketSnapshot,
        securitySnapshot: preparation.report.security,
        inputToken: inputToken,
        outputToken: outputToken,
        inputAmountNative: amountNative,
        inputAmountSmallestUnit: amount,
        estimatedSpendUSD: nil,
        quote: quote,
        submittedAt: now,
        createdAt: now,
        updatedAt: now
      )
      _ = try await workspaceStore.insertTradeIntent(intent)
    }
    await refreshTradeAutomationMetrics()
    return try await submitAndTrackManualSwap(
      request,
      intent: &intent,
      workspaceStore: workspaceStore
    )
  }

  private func submitAndTrackManualSwap(
    _ request: GMGNTradeSwapRequest,
    intent: inout TradeIntent,
    workspaceStore: WorkspaceStore
  ) async throws -> GMGNTradeOrderSnapshot {
    do {
      let submission = try await gmgnTradeClient.submitSwap(
        request,
        confirmedByUser: true
      )
      mergeTradeSnapshot(submission, into: &intent)
      intent.updatedAt = Date()
      _ = try await workspaceStore.updateTradeIntent(intent)
      await refreshTradeAutomationMetrics()

      guard let orderID = intent.orderID, !submission.isTerminal else {
        return submission
      }
      let receipt = try await gmgnTradeClient.waitForConfirmation(
        orderID: orderID,
        chain: request.chain,
        initial: submission,
        deadline: Date().addingTimeInterval(GMGNTradeClient.confirmationTimeout)
      )
      mergeTradeSnapshot(receipt, into: &intent)
      intent.updatedAt = Date()
      _ = try await workspaceStore.updateTradeIntent(intent)
      await refreshTradeAutomationMetrics()
      return receipt
    } catch {
      if intent.orderID != nil {
        intent.state = .pending
        intent.failureReason = "订单已提交，状态查询暂时失败：\(error.localizedDescription)"
      } else if case GMGNCLIError.submissionUncertain = error {
        intent.state = .submitting
        intent.failureReason = error.localizedDescription
      } else if error is CancellationError {
        intent.state = .submitting
        intent.failureReason = "交易提交被中断，结果待核对；请勿直接重复交易。"
      } else {
        intent.state = .failed
        intent.failureReason = error.localizedDescription
      }
      intent.updatedAt = Date()
      _ = try? await workspaceStore.updateTradeIntent(intent)
      await refreshTradeAutomationMetrics()
      throw error
    }
  }

  private func addressesEqual(_ lhs: String, _ rhs: String, chain: GMGNChain) -> Bool {
    chain == .sol ? lhs == rhs : lhs.caseInsensitiveCompare(rhs) == .orderedSame
  }

  private func sellHumanAmount(balance: String, percent: Int) -> Double {
    guard let value = Decimal(
      string: balance.trimmingCharacters(in: .whitespacesAndNewlines),
      locale: Locale(identifier: "en_US_POSIX")
    ) else { return 0 }
    return NSDecimalNumber(decimal: value * Decimal(percent) / 100).doubleValue
  }

  private func refreshPortfolioAfterTrade() async throws {
    let snapshot = try await gmgnTradeClient.portfolioInfo(forceRefresh: true)
    storeGMGNPortfolio(snapshot)
    gmgnPortfolioError = nil
  }

  private func gmgnChain(for network: CryptoAddressNetwork) -> GMGNChain? {
    switch network {
    case .solana: return .sol
    case .ethereum: return .eth
    case .base: return .base
    case .bsc: return .bsc
    case .robinhood: return .robinhood
    case .arbitrum, .polygon, .optimism, .avalanche, .evm: return nil
    }
  }

  private func prepareMemeMode(address: String, suggestedChain: GMGNChain?) {
    memeAddressDraft = address
    memeSelectedChain = suggestedChain
    memeChainSelectionAddress = suggestedChain == nil ? nil : memeAddressKey(address)
    memeChainCandidates = []
    memeChainDetectionMessage = suggestedChain.map {
      "已识别为 \($0.localizedTitle)"
    }
    memeQueryError = nil
    if memeTokenReport?.token.address != address
      || suggestedChain == nil
      || memeTokenReport?.token.chain != suggestedChain
    {
      memeTokenReport = nil
    }
    workspaceSelection = .meme
    if suggestedChain != nil {
      queryMemeToken()
    } else {
      handleMemeAddressChange(address)
      queryMemeToken()
    }
  }

  func handleMemeAddressChange(_ rawValue: String) {
    let address = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let addressKey = memeAddressKey(address)
    memeChainDetectionTask?.cancel()
    isDetectingMemeChain = false
    memeQueryError = nil

    if let report = memeTokenReport,
      memeAddressKey(report.token.address) != addressKey
    {
      memeQueryTask?.cancel()
      isQueryingMeme = false
      memeTokenReport = nil
    }

    if CryptoAddressDetector.matches(in: "SOL CA \(address)")
      .contains(where: { $0.family == .solana && $0.address == address })
    {
      memeSelectedChain = .sol
      memeChainSelectionAddress = addressKey
      memeChainCandidates = []
      memeChainDetectionMessage = "根据地址格式识别为 Solana"
      return
    }

    guard isValidEVMAddress(address) else {
      if memeChainSelectionAddress != addressKey {
        memeSelectedChain = nil
        memeChainSelectionAddress = nil
        memeChainCandidates = []
        memeChainDetectionMessage = nil
      }
      return
    }

    if memeChainSelectionAddress == addressKey, memeSelectedChain != nil {
      return
    }

    memeSelectedChain = nil
    memeChainSelectionAddress = nil
    memeChainCandidates = []
    memeChainDetectionMessage = "正在通过 DexScreener 识别网络"
    isDetectingMemeChain = true
    memeChainDetectionTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(320))
        guard let self else { return }
        let resolution = try await resolveEVMChain(address: address)
        try Task.checkCancellation()
        guard memeAddressKey(memeAddressDraft) == addressKey,
          memeChainSelectionAddress == nil
        else { return }
        applyMemeChainResolution(resolution)
      } catch is CancellationError {
        return
      } catch {
        guard let self, !Task.isCancelled,
          memeAddressKey(memeAddressDraft) == addressKey
        else { return }
        isDetectingMemeChain = false
        memeChainDetectionMessage = error.localizedDescription
      }
    }
  }

  func selectMemeChain(_ chain: GMGNChain?) {
    let address = memeAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    memeChainDetectionTask?.cancel()
    memeQueryTask?.cancel()
    isDetectingMemeChain = false
    isQueryingMeme = false
    memeTokenReport = nil
    memeQueryError = nil
    memeSelectedChain = chain
    memeChainSelectionAddress = chain == nil ? nil : memeAddressKey(address)
    memeChainCandidates = []
    memeChainDetectionMessage = chain.map { "已手动选择 \($0.localizedTitle)" }
    if chain == nil { handleMemeAddressChange(address) }
  }

  private func scheduleMemeMentionSummaryRefresh() {
    memeMentionSummaryTask?.cancel()
    let address = memeAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let family = memeAddressFamily(for: address) else {
      memeMentionSummary = nil
      memeMentionSummaryError = nil
      isLoadingMemeMentionSummary = false
      return
    }
    let network = memeSelectedChain?.cryptoAddressNetwork
      ?? (family == .solana ? .solana : .evm)
    guard let workspaceStore else {
      memeMentionSummary = nil
      memeMentionSummaryError = "本地群聊统计不可用"
      isLoadingMemeMentionSummary = false
      return
    }

    memeMentionSummary = nil
    memeMentionSummaryError = nil
    isLoadingMemeMentionSummary = true
    memeMentionSummaryTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(160))
        let end = Date().addingTimeInterval(0.001)
        let summary = try await workspaceStore.cryptoAddressMentionSummary(
          family: family,
          network: network,
          normalizedAddress: address,
          start: end.addingTimeInterval(-WorkspaceStore.crossGroupAddressWindow),
          end: end
        )
        try Task.checkCancellation()
        guard let self,
          self.memeAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines) == address,
          self.memeAddressFamily(for: address) == family,
          (self.memeSelectedChain?.cryptoAddressNetwork
            ?? (family == .solana ? .solana : .evm)) == network
        else { return }
        self.memeMentionSummary = summary
        self.memeMentionSummaryError = nil
        self.isLoadingMemeMentionSummary = false
      } catch is CancellationError {
        return
      } catch {
        guard let self, !Task.isCancelled else { return }
        self.memeMentionSummary = nil
        self.memeMentionSummaryError = error.localizedDescription
        self.isLoadingMemeMentionSummary = false
      }
    }
  }

  private func memeAddressFamily(for address: String) -> CryptoAddressFamily? {
    guard !address.isEmpty else { return nil }
    if address.lowercased().hasPrefix("0x") { return .evm }
    return CryptoAddressDetector.matches(in: "SOL CA \(address)")
      .first(where: { $0.family == .solana })?.family
  }

  func queryMemeToken() {
    let address = memeAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !address.isEmpty else {
      memeQueryError = "请输入代币地址。"
      return
    }
    let addressKey = memeAddressKey(address)
    memeQueryTask?.cancel()
    memeChainDetectionTask?.cancel()
    isQueryingMeme = true
    memeQueryError = nil
    memeQueryTask = Task { [weak self] in
      guard let self else { return }
      defer {
        isQueryingMeme = false
        isDetectingMemeChain = false
      }
      do {
        let chain: GMGNChain
        if let selected = memeSelectedChain,
          memeChainSelectionAddress == addressKey
        {
          chain = selected
        } else if isValidEVMAddress(address) {
          isDetectingMemeChain = true
          memeChainDetectionMessage = "正在通过 DexScreener 识别网络"
          let resolution = try await resolveEVMChain(address: address)
          try Task.checkCancellation()
          guard memeAddressKey(memeAddressDraft) == addressKey else { return }
          applyMemeChainResolution(resolution)
          guard let detected = resolution.selectedChain else {
            memeQueryError = resolution.candidates.isEmpty
              ? "DexScreener 没有找到支持网络的交易对，请手动选择网络。"
              : "该地址在多个网络都有交易对，且主流动性接近，请选择一个候选网络。"
            return
          }
          chain = detected
        } else if CryptoAddressDetector.matches(in: "SOL CA \(address)")
          .contains(where: { $0.family == .solana && $0.address == address })
        {
          chain = .sol
          memeSelectedChain = .sol
          memeChainSelectionAddress = addressKey
        } else {
          memeQueryError = "请输入完整代币地址。"
          return
        }
        do {
          memeTokenReport = try await gmgnClient.tokenReport(chain: chain, address: address)
        } catch let gmgnError as GMGNCLIError {
          let token = try await dexScreenerChainResolver.tokenSnapshot(
            chain: chain,
            address: address
          )
          memeTokenReport = GMGNTokenReport(
            token: token,
            security: nil,
            securityError: "GMGN 暂不可用（\(gmgnError.localizedDescription)），当前仅显示 DexScreener 基础行情。",
            fetchedAt: Date(),
            isCached: false,
            marketDataSource: .dexScreener
          )
        }
      } catch is CancellationError {
        return
      } catch {
        memeQueryError = error.localizedDescription
      }
    }
  }

  private func applyMemeChainResolution(_ resolution: DexScreenerChainResolution) {
    isDetectingMemeChain = false
    memeChainCandidates = resolution.candidates
    if let chain = resolution.selectedChain {
      memeSelectedChain = chain
      memeChainSelectionAddress = resolution.address
      let liquidity = resolution.candidates.first(where: { $0.chain == chain })?
        .maxLiquidityUSD
      let source = resolution.source == .persistentCache ? "本地链识别缓存" : "DexScreener"
      memeChainDetectionMessage = "\(source)识别为 \(chain.localizedTitle)\(formattedDetectionLiquidity(liquidity))"
    } else if resolution.candidates.isEmpty {
      memeSelectedChain = nil
      memeChainSelectionAddress = nil
      memeChainDetectionMessage = "DexScreener 未找到支持网络的交易对"
    } else {
      memeSelectedChain = nil
      memeChainSelectionAddress = nil
      memeChainDetectionMessage = "检测到多个接近的网络，请确认候选"
    }
  }

  private func formattedDetectionLiquidity(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "" }
    let magnitude = abs(value)
    let formatted: String
    if magnitude >= 1_000_000_000 {
      formatted = "$" + (value / 1_000_000_000).formatted(
        .number.precision(.fractionLength(0...1))
      ) + "B"
    } else if magnitude >= 1_000_000 {
      formatted = "$" + (value / 1_000_000).formatted(
        .number.precision(.fractionLength(0...1))
      ) + "M"
    } else if magnitude >= 1_000 {
      formatted = "$" + (value / 1_000).formatted(
        .number.precision(.fractionLength(0...1))
      ) + "K"
    } else {
      formatted = value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
    }
    return " · 主池流动性 " + formatted
  }

  private func memeAddressKey(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.lowercased().hasPrefix("0x") ? trimmed.lowercased() : trimmed
  }

  private func isValidEVMAddress(_ value: String) -> Bool {
    let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return address.count == 42
      && address.lowercased().hasPrefix("0x")
      && address.dropFirst(2).allSatisfy(\.isHexDigit)
  }

  func caSignalEnrichment(
    eventID: String,
    match: CryptoAddressMatch
  ) -> CASignalEnrichment? {
    caSignalEnrichments[caSignalKey(
      eventID: eventID,
      family: match.family,
      network: match.network,
      address: match.normalizedAddress
    )]
  }

  func caTokenSnapshot(
    eventID: String,
    match: CryptoAddressMatch
  ) -> CATokenMarketSnapshot? {
    caSignalEnrichment(eventID: eventID, match: match)?.snapshot
      ?? latestCASignalSnapshot(
        family: match.family,
        network: match.network,
        address: match.normalizedAddress
      )
      ?? caWatchPoolItem(for: match)?.currentSnapshot
      ?? caWatchPoolItem(for: match)?.entrySnapshot
  }

  func caTokenSnapshot(for address: AIAnalysisCryptoAddress) -> CATokenMarketSnapshot? {
    let family: CryptoAddressFamily = address.normalizedAddress.lowercased().hasPrefix("0x")
      ? .evm : .solana
    for eventID in address.sourceMessageIDs {
      let key = caSignalKey(
        eventID: eventID,
        family: family,
        network: address.network,
        address: address.normalizedAddress
      )
      if let snapshot = caSignalEnrichments[key]?.snapshot { return snapshot }
    }
    return latestCASignalSnapshot(
      family: family,
      network: address.network,
      address: address.normalizedAddress
    )
      ?? caWatchPoolItems.first(where: {
        $0.family == family && $0.normalizedAddress == address.normalizedAddress
      })?.currentSnapshot
      ?? removedCAWatchPoolItems.first(where: {
        $0.family == family && $0.normalizedAddress == address.normalizedAddress
      })?.currentSnapshot
  }

  func caTokenSnapshot(for incident: CrossGroupAddressIncident) -> CATokenMarketSnapshot? {
    for eventID in incident.sourceEventIDs {
      let key = caSignalKey(
        eventID: eventID,
        family: incident.family,
        network: incident.network,
        address: incident.normalizedAddress
      )
      if let snapshot = caSignalEnrichments[key]?.snapshot { return snapshot }
    }
    let poolKey = caPoolItemKey(
      family: incident.family,
      network: incident.network,
      address: incident.normalizedAddress
    )
    return caWatchPoolItems.first(where: { $0.id == poolKey })?.currentSnapshot
      ?? removedCAWatchPoolItems.first(where: { $0.id == poolKey })?.currentSnapshot
  }

  /// Returns only a snapshot bound to one of the incident's source events.
  /// This intentionally avoids the watch pool's current snapshot, which may be newer.
  func caTriggerSnapshot(for incident: CrossGroupAddressIncident) -> CATokenMarketSnapshot? {
    // Source event IDs are stored oldest-first; the latest source is the one that
    // caused the most recent cross-group notification update.
    for eventID in incident.sourceEventIDs.reversed() {
      let key = caSignalKey(
        eventID: eventID,
        family: incident.family,
        network: incident.network,
        address: incident.normalizedAddress
      )
      if let snapshot = caSignalEnrichments[key]?.snapshot {
        return snapshot
      }
    }
    return nil
  }

  func caWatchPoolItem(for match: CryptoAddressMatch) -> CAWatchPoolItem? {
    let identifier = caPoolItemKey(
      family: match.family,
      network: match.network,
      address: match.normalizedAddress
    )
    return caWatchPoolItems.first { $0.id == identifier }
      ?? removedCAWatchPoolItems.first { $0.id == identifier }
  }

  func updateCAWatchPoolEnabled(_ enabled: Bool) {
    var configuration = caWatchPoolConfiguration
    configuration.isEnabled = enabled
    saveCAWatchPoolConfiguration(configuration)
  }

  func updateCAWatchPoolCapacity(_ capacity: Int) {
    var configuration = caWatchPoolConfiguration
    configuration.capacity = capacity
    saveCAWatchPoolConfiguration(configuration)
  }

  func updateCAWatchPoolMinimumMarketCap(_ value: Double) {
    var configuration = caWatchPoolConfiguration
    configuration.minimumMarketCapUSD = value
    saveCAWatchPoolConfiguration(configuration)
  }

  func updateCAWatchPoolRefreshInterval(_ seconds: TimeInterval) {
    var configuration = caWatchPoolConfiguration
    configuration.refreshIntervalSeconds = seconds
    saveCAWatchPoolConfiguration(configuration)
  }

  func updateCAWatchPoolGraceAttempts(_ count: Int) {
    var configuration = caWatchPoolConfiguration
    configuration.graceAttemptCount = count
    saveCAWatchPoolConfiguration(configuration)
  }

  func updateCAWatchPoolConfiguration(_ configuration: CAWatchPoolConfiguration) {
    saveCAWatchPoolConfiguration(configuration)
  }

  func refreshCAWatchPoolNow() {
    caWatchPoolDebounceTask?.cancel()
    caWatchPoolDebounceTask = Task { [weak self] in
      await self?.refreshCAWatchPool()
    }
  }

  func refreshMarketTrends(
    chain: GMGNChain,
    interval: GMGNMarketInterval,
    orderBy: GMGNMarketOrderBy = .default,
    direction: GMGNMarketDirection = .descending,
    forceRefresh: Bool = false
  ) {
    let requestKey = "\(chain.rawValue):\(interval.rawValue):\(orderBy.rawValue):\(direction.rawValue)"
    let shouldResetResults = marketTrendingRequestKey != requestKey
    marketTrendingRequestKey = requestKey
    marketTrendingTask?.cancel()
    if shouldResetResults {
      marketTrendingTokens = []
      marketTrendingLastRefreshAt = nil
    }
    marketTrendingTask = Task { [weak self] in
      guard let self else { return }
      self.isLoadingMarketTrends = true
      self.marketTrendingError = nil
      defer {
        if self.marketTrendingRequestKey == requestKey {
          self.isLoadingMarketTrends = false
        }
      }
      do {
        let tokens = try await self.gmgnClient.trendingTokens(
          chain: chain,
          interval: interval,
          orderBy: orderBy,
          direction: direction,
          limit: 10,
          forceRefresh: forceRefresh
        )
        guard !Task.isCancelled, self.marketTrendingRequestKey == requestKey else { return }
        self.marketTrendingTokens = tokens
        self.marketTrendingLastRefreshAt = Date()
      } catch is CancellationError {
        return
      } catch {
        guard self.marketTrendingRequestKey == requestKey else { return }
        self.marketTrendingError = error.localizedDescription
      }
    }
  }

  func toggleCAWatchPoolPin(_ item: CAWatchPoolItem) {
    guard let index = caWatchPoolItems.firstIndex(where: { $0.id == item.id }) else { return }
    caWatchPoolItems[index].isPinned.toggle()
    caWatchPoolItems[index].updatedAt = Date()
    persistCAWatchPoolItem(caWatchPoolItems[index])
  }

  func removeCAWatchPoolItem(_ item: CAWatchPoolItem) {
    moveCAWatchPoolItemToRemoved(item.id, reason: "手动移出")
  }

  func restoreCAWatchPoolItem(_ item: CAWatchPoolItem) {
    guard let index = removedCAWatchPoolItems.firstIndex(where: { $0.id == item.id }) else {
      return
    }
    var restored = removedCAWatchPoolItems.remove(at: index)
    restored.state = restored.currentSnapshot == nil ? .pending : .watching
    restored.removalReason = nil
    restored.belowThresholdCount = 0
    restored.consecutiveFailures = 0
    restored.updatedAt = Date()
    caWatchPoolItems.insert(restored, at: 0)
    enforceCAWatchPoolCapacity()
    persistCAWatchPoolItem(restored)
    requestCAWatchPoolRefresh()
  }

  func retryCASignal(eventID: String, match: CryptoAddressMatch) {
    let key = caSignalKey(
      eventID: eventID,
      family: match.family,
      network: match.network,
      address: match.normalizedAddress
    )
    guard var enrichment = caSignalEnrichments[key] else { return }
    enrichment.state = .pending
    enrichment.lastErrorCode = nil
    enrichment.updatedAt = Date()
    caSignalEnrichments[key] = enrichment
    persistCASignalEnrichment(enrichment)
    if let removed = removedCAWatchPoolItems.first(where: { $0.id == caPoolItemKey(
      family: match.family,
      network: match.network,
      address: match.normalizedAddress
    ) }) {
      restoreCAWatchPoolItem(removed)
    } else if caWatchPoolItem(for: match) == nil,
      let event = messages.first(where: { $0.eventID == eventID })
    {
      upsertCAWatchPoolItem(match: match, event: event)
      enforceCAWatchPoolCapacity()
    }
    if caWatchPoolConfiguration.isEnabled {
      requestCAWatchPoolRefresh()
    } else {
      requestStandaloneCAEnrichment([match])
    }
  }

  private func loadCAWatchPool() async {
    guard let workspaceStore else { return }
    do {
      if let savedConfiguration = try await workspaceStore.caWatchPoolConfiguration() {
        caWatchPoolConfiguration = savedConfiguration
      } else {
        caWatchPoolConfiguration = try await workspaceStore.saveCAWatchPoolConfiguration(
          caWatchPoolConfiguration
        )
      }
      let items = try await workspaceStore.caWatchPoolItems(limit: 100)
      let activeItems = items.filter { $0.state != .removed }
      let normalizedPool = deduplicatedCAWatchPoolItems(activeItems)
      caWatchPoolItems = normalizedPool.items
      for duplicate in normalizedPool.duplicates {
        let network = duplicate.network
          ?? (duplicate.family == .solana ? .solana : .evm)
        try? await workspaceStore.deleteCAWatchPoolItem(
          family: duplicate.family,
          network: network,
          normalizedAddress: duplicate.normalizedAddress
        )
      }
      removedCAWatchPoolItems = Array(items.filter { $0.state == .removed }.prefix(30))
      // Older versions could persist more active rows than the configured
      // capacity. Normalize that state before starting the first refresh so
      // the displayed count and the refreshed set describe the same pool.
      enforceCAWatchPoolCapacity()
      let unresolved = try await workspaceStore.caSignalEnrichments(
        states: [.pending, .failed],
        limit: 500
      )
      mergeCASignalEnrichments(unresolved)
      caWatchPoolError = nil
      restartCAWatchPoolMonitor()
      if caWatchPoolConfiguration.isEnabled {
        requestCAWatchPoolRefresh()
      }
    } catch {
      caWatchPoolError = "无法载入 CA 观察池：\(error.localizedDescription)"
    }
  }

  private func saveCAWatchPoolConfiguration(_ configuration: CAWatchPoolConfiguration) {
    let normalized = configuration.normalized
    let wasEnabled = caWatchPoolConfiguration.isEnabled
    caWatchPoolConfiguration = normalized
    enforceCAWatchPoolCapacity()
    restartCAWatchPoolMonitor()
    guard let workspaceStore else { return }
    Task { [weak self] in
      do {
        _ = try await workspaceStore.saveCAWatchPoolConfiguration(normalized)
        self?.caWatchPoolError = nil
        if normalized.isEnabled {
          self?.requestCAWatchPoolRefresh()
          if !wasEnabled { self?.scheduleAddressBackfill() }
        }
      } catch {
        self?.caWatchPoolError = "无法保存观察池设置：\(error.localizedDescription)"
      }
    }
  }

  private func restartCAWatchPoolMonitor() {
    caWatchPoolMonitorTask?.cancel()
    caWatchPoolMonitorTask = nil
    guard caWatchPoolConfiguration.isEnabled else {
      caWatchPoolNextRefreshAt = nil
      return
    }
    caWatchPoolNextRefreshAt = Date().addingTimeInterval(
      caWatchPoolConfiguration.refreshIntervalSeconds
    )
    caWatchPoolMonitorTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let interval = self.caWatchPoolConfiguration.refreshIntervalSeconds
        do {
          try await Task.sleep(for: .seconds(interval))
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        await self.refreshCAWatchPool()
      }
    }
  }

  private func requestCAWatchPoolRefresh() {
    guard caWatchPoolConfiguration.isEnabled else { return }
    caWatchPoolDebounceTask?.cancel()
    caWatchPoolDebounceTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(2))
      } catch {
        return
      }
      await self?.refreshCAWatchPool()
    }
  }

  private func refreshCAWatchPool() async {
    guard caWatchPoolConfiguration.isEnabled, !isRefreshingCAWatchPool else { return }
    guard !caWatchPoolItems.isEmpty else {
      caWatchPoolNextRefreshAt = nil
      return
    }
    isRefreshingCAWatchPool = true
    defer { isRefreshingCAWatchPool = false }

    let items = caWatchPoolItems
      .sorted {
        if $0.isPinned != $1.isPinned { return $0.isPinned }
        return $0.latestSeenAt > $1.latestSeenAt
      }
      .prefix(caWatchPoolConfiguration.capacity)

    var errors: [String] = []
    var succeededCount = 0
    var failedCount = 0
    await withTaskGroup(of: CAWatchPoolRefreshOutcome.self) { group in
      for item in items {
        group.addTask { [weak self] in
          guard let self else { return .cancelled }
          do {
            let chain = try await self.chainForCAWatchPoolItem(item)
            let checkedAt = Date()
            let snapshot: CATokenMarketSnapshot
            do {
              // DexScreener is a lightweight, public market-data path and is
              // less likely to trip the GMGN CLI limiter during pool refreshes.
              let token = try await self.dexScreenerChainResolver.tokenSnapshot(
                chain: chain,
                address: item.normalizedAddress,
                now: checkedAt
              )
              snapshot = CATokenMarketSnapshot(
                token: token,
                capturedAt: checkedAt,
                source: .dexScreener
              )
            } catch {
              let token = try await self.gmgnClient.tokenSnapshot(
                chain: chain,
                address: item.normalizedAddress,
                now: checkedAt
              )
              snapshot = CATokenMarketSnapshot(token: token, capturedAt: checkedAt)
            }
            return .success(identifier: item.id, snapshot: snapshot)
          } catch is CancellationError {
            return .cancelled
          } catch {
            return .failure(
              identifier: item.id,
              message: error.localizedDescription,
              errorCode: self.caMarketErrorCode(error)
            )
          }
        }
      }

      for await outcome in group {
        guard !Task.isCancelled else { return }
        switch outcome {
        case .success(let identifier, let snapshot):
          do {
            try await applyCAWatchPoolSnapshot(snapshot, to: identifier)
            succeededCount += 1
          } catch {
            errors.append(error.localizedDescription)
            failedCount += 1
            await applyCAWatchPoolFailure(to: identifier, error: error)
          }
        case .failure(let identifier, let message, let errorCode):
          errors.append(message)
          failedCount += 1
          await applyCAWatchPoolFailure(
            to: identifier,
            error: CAWatchPoolRuntimeError.marketDataIncomplete,
            errorCode: errorCode
          )
        case .cancelled:
          continue
        }
      }
    }
    caWatchPoolLastRefreshAt = Date()
    caWatchPoolNextRefreshAt = Date().addingTimeInterval(caWatchPoolConfiguration.refreshIntervalSeconds)
    caWatchPoolLastRefreshSucceededCount = succeededCount
    caWatchPoolLastRefreshFailedCount = failedCount
    caWatchPoolError = errors.isEmpty
      ? nil
      : "\(errors.count) 个 CA 刷新失败：\(errors[0])"
  }

  private func chainForCAWatchPoolItem(_ item: CAWatchPoolItem) async throws -> GMGNChain {
    if let chain = item.chain {
      normalizeCAWatchPoolNetwork(for: item, chain: chain)
      return chain
    }
    if item.family == .solana { return .sol }
    let resolution = try await resolveEVMChain(address: item.normalizedAddress)
    guard let chain = resolution.selectedChain else {
      throw CAWatchPoolRuntimeError.chainUnresolved
    }
    normalizeCAWatchPoolNetwork(for: item, chain: chain)
    return chain
  }

  private func normalizeCAWatchPoolNetwork(for item: CAWatchPoolItem, chain: GMGNChain) {
    guard let index = caWatchPoolItems.firstIndex(where: { $0.id == item.id }) else { return }
    let resolvedNetwork = chain.cryptoAddressNetwork
    if item.network == resolvedNetwork, item.chain == chain { return }

    if let duplicateIndex = caWatchPoolItems.firstIndex(where: {
      $0.id != item.id
        && $0.family == item.family
        && $0.normalizedAddress == item.normalizedAddress
        && $0.network == resolvedNetwork
    }) {
      var merged = caWatchPoolItems[duplicateIndex]
      merged.chain = chain
      merged.isPinned = merged.isPinned || item.isPinned
      merged.mentionCount = max(merged.mentionCount, item.mentionCount)
      merged.groupNames = Array(Set(merged.groupNames + item.groupNames)).sorted()
      merged.latestSeenAt = max(merged.latestSeenAt, item.latestSeenAt)
      merged.entrySnapshot = merged.entrySnapshot ?? item.entrySnapshot
      merged.currentSnapshot = merged.currentSnapshot ?? item.currentSnapshot
      merged.lastCheckedAt = max(merged.lastCheckedAt ?? .distantPast, item.lastCheckedAt ?? .distantPast)
      merged.consecutiveFailures = min(merged.consecutiveFailures, item.consecutiveFailures)
      merged.belowThresholdCount = max(merged.belowThresholdCount, item.belowThresholdCount)
      merged.updatedAt = max(merged.updatedAt, item.updatedAt, Date())
      caWatchPoolItems[duplicateIndex] = merged
      caWatchPoolItems.remove(at: index)
      persistCAWatchPoolItem(merged)
      deletePersistedCAWatchPoolItem(item)
      return
    }

    caWatchPoolItems[index].network = resolvedNetwork
    caWatchPoolItems[index].chain = chain
    caWatchPoolItems[index].updatedAt = Date()
    persistCAWatchPoolItem(caWatchPoolItems[index])
    deletePersistedCAWatchPoolItem(item)
  }

  private func deduplicatedCAWatchPoolItems(
    _ items: [CAWatchPoolItem]
  ) -> (items: [CAWatchPoolItem], duplicates: [CAWatchPoolItem]) {
    let ordered = items.sorted { lhs, rhs in
      let lhsUnknown = lhs.network == .evm && lhs.chain != nil
      let rhsUnknown = rhs.network == .evm && rhs.chain != nil
      if lhsUnknown != rhsUnknown { return !lhsUnknown }
      return lhs.latestSeenAt > rhs.latestSeenAt
    }
    var result: [CAWatchPoolItem] = []
    var duplicates: [CAWatchPoolItem] = []
    for item in ordered {
      guard item.network == .evm, let resolvedNetwork = item.chain?.cryptoAddressNetwork else {
        result.append(item)
        continue
      }
      guard let index = result.firstIndex(where: {
        $0.family == item.family
          && $0.normalizedAddress == item.normalizedAddress
          && $0.network == resolvedNetwork
      }) else {
        result.append(item)
        continue
      }
      var merged = result[index]
      merged.isPinned = merged.isPinned || item.isPinned
      merged.mentionCount = max(merged.mentionCount, item.mentionCount)
      merged.groupNames = Array(Set(merged.groupNames + item.groupNames)).sorted()
      merged.latestSeenAt = max(merged.latestSeenAt, item.latestSeenAt)
      merged.entrySnapshot = merged.entrySnapshot ?? item.entrySnapshot
      merged.currentSnapshot = merged.currentSnapshot ?? item.currentSnapshot
      merged.lastCheckedAt = max(merged.lastCheckedAt ?? .distantPast, item.lastCheckedAt ?? .distantPast)
      merged.updatedAt = max(merged.updatedAt, item.updatedAt)
      result[index] = merged
      duplicates.append(item)
    }
    return (result, duplicates)
  }

  private func deletePersistedCAWatchPoolItem(_ item: CAWatchPoolItem) {
    guard let workspaceStore else { return }
    let network = item.network ?? (item.family == .solana ? .solana : .evm)
    Task {
      try? await workspaceStore.deleteCAWatchPoolItem(
        family: item.family,
        network: network,
        normalizedAddress: item.normalizedAddress
      )
    }
  }

  private func applyCAWatchPoolSnapshot(
    _ snapshot: CATokenMarketSnapshot,
    to identifier: String
  ) async throws {
    guard let index = caWatchPoolItems.firstIndex(where: { $0.id == identifier }) else {
      return
    }
    guard !snapshot.name.isEmpty || !snapshot.symbol.isEmpty else {
      throw CAWatchPoolRuntimeError.marketDataIncomplete
    }

    let now = snapshot.capturedAt
    caWatchPoolItems[index].chain = snapshot.chain
    caWatchPoolItems[index].network = snapshot.chain.cryptoAddressNetwork
    caWatchPoolItems[index].currentSnapshot = snapshot
    if caWatchPoolItems[index].entrySnapshot == nil {
      caWatchPoolItems[index].entrySnapshot = snapshot
    }
    caWatchPoolItems[index].state = .watching
    caWatchPoolItems[index].lastCheckedAt = now
    caWatchPoolItems[index].consecutiveFailures = 0
    caWatchPoolItems[index].updatedAt = now

    if let marketCap = snapshot.marketCapUSD {
      if marketCap < caWatchPoolConfiguration.minimumMarketCapUSD {
        caWatchPoolItems[index].belowThresholdCount += 1
      } else {
        caWatchPoolItems[index].belowThresholdCount = 0
      }
    } else {
      caWatchPoolItems[index].consecutiveFailures += 1
    }

    let updatedItem = caWatchPoolItems[index]
    let resolvedIdentifier = updatedItem.id
    await resolvePendingCASignals(
      family: updatedItem.family,
      network: updatedItem.network,
      address: updatedItem.normalizedAddress,
      snapshot: snapshot
    )

    if updatedItem.isPinned {
      persistCAWatchPoolItem(updatedItem)
      return
    }
    if updatedItem.belowThresholdCount >= caWatchPoolConfiguration.graceAttemptCount {
      moveCAWatchPoolItemToRemoved(
        resolvedIdentifier,
        reason: "市值连续低于 \(formattedCAThreshold(caWatchPoolConfiguration.minimumMarketCapUSD))"
      )
    } else if updatedItem.consecutiveFailures >= caWatchPoolConfiguration.graceAttemptCount {
      moveCAWatchPoolItemToRemoved(resolvedIdentifier, reason: "连续无法获得市值")
    } else {
      persistCAWatchPoolItem(updatedItem)
    }
  }

  private func applyCAWatchPoolFailure(
    to identifier: String,
    error: Error,
    errorCode: String? = nil
  ) async {
    guard let index = caWatchPoolItems.firstIndex(where: { $0.id == identifier }) else {
      return
    }
    caWatchPoolItems[index].lastCheckedAt = Date()
    caWatchPoolItems[index].consecutiveFailures += 1
    caWatchPoolItems[index].updatedAt = Date()
    let item = caWatchPoolItems[index]
    await failPendingCASignals(
      family: item.family,
      network: item.network,
      address: item.normalizedAddress,
      errorCode: errorCode ?? caMarketErrorCode(error)
    )
    if !item.isPinned,
      item.consecutiveFailures >= caWatchPoolConfiguration.graceAttemptCount
    {
      moveCAWatchPoolItemToRemoved(identifier, reason: "连续 \(item.consecutiveFailures) 次查询失败")
    } else {
      persistCAWatchPoolItem(item)
    }
  }

  private func resolvePendingCASignals(
    family: CryptoAddressFamily,
    network: CryptoAddressNetwork? = nil,
    address: String,
    snapshot: CATokenMarketSnapshot
  ) async {
    guard let workspaceStore else { return }
    let keys = caSignalEnrichments.compactMap { key, enrichment in
      enrichment.family == family
        && (network == nil || enrichment.network == network)
        && enrichment.normalizedAddress == address
        && enrichment.state != .resolved ? key : nil
    }
    for key in keys {
      guard var enrichment = caSignalEnrichments[key] else { continue }
      enrichment.state = .resolved
      enrichment.snapshot = snapshot
      enrichment.attemptCount += 1
      enrichment.lastErrorCode = nil
      enrichment.updatedAt = Date()
      caSignalEnrichments[key] = enrichment
      indexCASignalSnapshot(enrichment)
      do {
        _ = try await workspaceStore.saveCASignalEnrichment(enrichment)
      } catch {
        caWatchPoolError = "无法保存 CA 触发快照：\(error.localizedDescription)"
      }
    }
  }

  private func failPendingCASignals(
    family: CryptoAddressFamily,
    network: CryptoAddressNetwork? = nil,
    address: String,
    errorCode: String
  ) async {
    guard let workspaceStore else { return }
    let keys = caSignalEnrichments.compactMap { key, enrichment in
      enrichment.family == family
        && (network == nil || enrichment.network == network)
        && enrichment.normalizedAddress == address
        && enrichment.state != .resolved ? key : nil
    }
    for key in keys {
      guard var enrichment = caSignalEnrichments[key] else { continue }
      enrichment.state = .failed
      enrichment.attemptCount += 1
      enrichment.lastErrorCode = errorCode
      enrichment.updatedAt = Date()
      caSignalEnrichments[key] = enrichment
      _ = try? await workspaceStore.saveCASignalEnrichment(enrichment)
    }
  }

  private func recordCASignals(
    _ matches: [CryptoAddressMatch],
    event: MessageEvent
  ) async {
    guard let workspaceStore else { return }
    for match in matches {
      let signalKey = caSignalKey(
        eventID: event.eventID,
        family: match.family,
        network: match.network,
        address: match.normalizedAddress
      )
      if caSignalEnrichments[signalKey] == nil {
        let cachedSnapshot = caWatchPoolItem(for: match)?.currentSnapshot.flatMap { snapshot in
          Date().timeIntervalSince(snapshot.capturedAt) < GMGNCLIClient.cacheTTL
            ? snapshot : nil
        }
        let enrichment = CASignalEnrichment(
          eventID: event.eventID,
          family: match.family,
          network: match.network,
          normalizedAddress: match.normalizedAddress,
          state: cachedSnapshot == nil ? .pending : .resolved,
          snapshot: cachedSnapshot
        )
        caSignalEnrichments[signalKey] = enrichment
        do {
          _ = try await workspaceStore.saveCASignalEnrichment(enrichment)
        } catch {
          caWatchPoolError = "无法记录 CA 信号：\(error.localizedDescription)"
        }
      }
      guard caWatchPoolConfiguration.isEnabled else { continue }
      upsertCAWatchPoolItem(match: match, event: event)
    }
    guard caWatchPoolConfiguration.isEnabled else {
      requestStandaloneCAEnrichment(matches)
      return
    }
    enforceCAWatchPoolCapacity()
    requestCAWatchPoolRefresh()
  }

  private func requestStandaloneCAEnrichment(_ matches: [CryptoAddressMatch]) {
    var seen = Set<String>()
    for match in matches {
      let key = caPoolItemKey(
        family: match.family,
        network: match.network,
        address: match.normalizedAddress
      )
      guard seen.insert(key).inserted, standaloneCAEnrichmentTasks[key] == nil else {
        continue
      }
      standaloneCAEnrichmentTasks[key] = Task { [weak self] in
        guard let self else { return }
        await self.resolveStandaloneCAEnrichment(match)
        self.standaloneCAEnrichmentTasks[key] = nil
      }
    }
  }

  private func resolveStandaloneCAEnrichment(_ match: CryptoAddressMatch) async {
    do {
      let chain: GMGNChain
      if match.family == .solana {
        chain = .sol
      } else {
        switch match.network {
        case .ethereum: chain = .eth
        case .base: chain = .base
        case .bsc: chain = .bsc
        case .robinhood: chain = .robinhood
        default:
          let resolution = try await resolveEVMChain(address: match.normalizedAddress)
          guard let selected = resolution.selectedChain else {
            throw CAWatchPoolRuntimeError.chainUnresolved
          }
          chain = selected
        }
      }
      let token = try await dexScreenerChainResolver.tokenSnapshot(
        chain: chain,
        address: match.normalizedAddress
      )
      guard !token.name.isEmpty || !token.symbol.isEmpty else {
        throw CAWatchPoolRuntimeError.marketDataIncomplete
      }
      await resolvePendingCASignals(
        family: match.family,
        network: match.network,
        address: match.normalizedAddress,
        snapshot: CATokenMarketSnapshot(token: token, source: .dexScreener)
      )
    } catch is CancellationError {
      return
    } catch {
      await failPendingCASignals(
        family: match.family,
        network: match.network,
        address: match.normalizedAddress,
        errorCode: caMarketErrorCode(error)
      )
    }
  }

  private func upsertCAWatchPoolItem(match: CryptoAddressMatch, event: MessageEvent) {
    let identifier = caPoolItemKey(
      family: match.family,
      network: match.network,
      address: match.normalizedAddress
    )
    if let index = caWatchPoolItems.firstIndex(where: { $0.id == identifier }) {
      if event.observedAt > caWatchPoolItems[index].latestSeenAt {
        caWatchPoolItems[index].mentionCount += 1
        caWatchPoolItems[index].latestSeenAt = event.observedAt
      }
      if !caWatchPoolItems[index].groupNames.contains(event.group) {
        caWatchPoolItems[index].groupNames.append(event.group)
      }
      caWatchPoolItems[index].updatedAt = Date()
      persistCAWatchPoolItem(caWatchPoolItems[index])
      return
    }

    // An address detected before chain resolution may arrive again as a
    // concrete network. Reuse the resolved row instead of adding a duplicate.
    if match.network == .evm,
      let resolvedIndex = caWatchPoolItems.firstIndex(where: {
        $0.family == match.family
          && $0.normalizedAddress == match.normalizedAddress
          && $0.network != .evm
      })
    {
      if event.observedAt > caWatchPoolItems[resolvedIndex].latestSeenAt {
        caWatchPoolItems[resolvedIndex].mentionCount += 1
        caWatchPoolItems[resolvedIndex].latestSeenAt = event.observedAt
      }
      if !caWatchPoolItems[resolvedIndex].groupNames.contains(event.group) {
        caWatchPoolItems[resolvedIndex].groupNames.append(event.group)
      }
      caWatchPoolItems[resolvedIndex].updatedAt = Date()
      persistCAWatchPoolItem(caWatchPoolItems[resolvedIndex])
      return
    }

    if let removedIndex = removedCAWatchPoolItems.firstIndex(where: { $0.id == identifier }) {
      var restored = removedCAWatchPoolItems.remove(at: removedIndex)
      restored.state = restored.currentSnapshot == nil ? .pending : .watching
      restored.removalReason = nil
      restored.latestSeenAt = max(restored.latestSeenAt, event.observedAt)
      restored.mentionCount += 1
      if !restored.groupNames.contains(event.group) { restored.groupNames.append(event.group) }
      restored.updatedAt = Date()
      caWatchPoolItems.insert(restored, at: 0)
      persistCAWatchPoolItem(restored)
      return
    }

    let chain: GMGNChain? = match.family == .solana ? .sol : nil
    let item = CAWatchPoolItem(
      family: match.family,
      network: match.network,
      normalizedAddress: match.normalizedAddress,
      chain: chain,
      groupNames: [event.group],
      firstSeenAt: event.observedAt,
      latestSeenAt: event.observedAt
    )
    caWatchPoolItems.insert(item, at: 0)
    persistCAWatchPoolItem(item)
  }

  private func enforceCAWatchPoolCapacity() {
    while caWatchPoolItems.count > caWatchPoolConfiguration.capacity {
      guard let candidate = caWatchPoolItems
        .filter({ !$0.isPinned })
        .min(by: { $0.latestSeenAt < $1.latestSeenAt })
      else { break }
      moveCAWatchPoolItemToRemoved(candidate.id, reason: "超过观察池容量")
    }
  }

  private func moveCAWatchPoolItemToRemoved(_ identifier: String, reason: String) {
    guard let index = caWatchPoolItems.firstIndex(where: { $0.id == identifier }) else {
      return
    }
    var item = caWatchPoolItems.remove(at: index)
    item.state = .removed
    item.removalReason = reason
    item.updatedAt = Date()
    removedCAWatchPoolItems.removeAll { $0.id == item.id }
    removedCAWatchPoolItems.insert(item, at: 0)
    if removedCAWatchPoolItems.count > 30 {
      removedCAWatchPoolItems = Array(removedCAWatchPoolItems.prefix(30))
    }
    persistCAWatchPoolItem(item)
  }

  private func persistCAWatchPoolItem(_ item: CAWatchPoolItem) {
    guard let workspaceStore else { return }
    Task { [weak self] in
      do {
        _ = try await workspaceStore.saveCAWatchPoolItem(item)
      } catch {
        self?.caWatchPoolError = "无法保存观察池：\(error.localizedDescription)"
      }
    }
  }

  private func persistCASignalEnrichment(_ enrichment: CASignalEnrichment) {
    guard let workspaceStore else { return }
    Task { [weak self] in
      do {
        _ = try await workspaceStore.saveCASignalEnrichment(enrichment)
      } catch {
        self?.caWatchPoolError = "无法保存 CA 信号：\(error.localizedDescription)"
      }
    }
  }

  private func mergeCASignalEnrichments(_ enrichments: [CASignalEnrichment]) {
    for enrichment in enrichments {
      caSignalEnrichments[enrichment.id] = enrichment
      indexCASignalSnapshot(enrichment)
    }
    if caSignalEnrichments.count > 2_500 {
      let retained = caSignalEnrichments.values
        .sorted { $0.updatedAt > $1.updatedAt }
        .prefix(2_000)
      caSignalEnrichments = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
    }
  }

  private func indexCASignalSnapshot(_ enrichment: CASignalEnrichment) {
    guard let snapshot = enrichment.snapshot else { return }
    let network = enrichment.network ?? (enrichment.family == .solana ? .solana : .evm)
    let key = "\(enrichment.family.rawValue):\(network.rawValue):\(enrichment.normalizedAddress)"
    if latestCASignalSnapshotIndex[key]?.updatedAt ?? .distantPast < enrichment.updatedAt {
      latestCASignalSnapshotIndex[key] = (enrichment.updatedAt, snapshot)
    }
  }

  private func latestCASignalSnapshot(
    family: CryptoAddressFamily,
    network: CryptoAddressNetwork? = nil,
    address: String
  ) -> CATokenMarketSnapshot? {
    let resolvedNetwork = network ?? (family == .solana ? .solana : .evm)
    return latestCASignalSnapshotIndex[
      "\(family.rawValue):\(resolvedNetwork.rawValue):\(address)"
    ]?.snapshot
  }

  private func caSignalKey(
    eventID: String,
    family: CryptoAddressFamily,
    network: CryptoAddressNetwork? = nil,
    address: String
  ) -> String {
    let resolvedNetwork = network ?? (family == .solana ? .solana : .evm)
    return "\(eventID):\(resolvedNetwork.rawValue):\(address)"
  }

  private func caPoolItemKey(
    family: CryptoAddressFamily,
    network: CryptoAddressNetwork? = nil,
    address: String
  ) -> String {
    let resolvedNetwork = network ?? (family == .solana ? .solana : .evm)
    return "\(family.rawValue):\(resolvedNetwork.rawValue):\(address)"
  }

  nonisolated private func caMarketErrorCode(_ error: Error) -> String {
    if error is CAWatchPoolRuntimeError { return "metadata_unavailable" }
    if error is DexScreenerChainResolverError { return "chain_resolution_failed" }
    if let gmgnError = error as? GMGNCLIError, case .rateLimited = gmgnError {
      return "gmgn_rate_limited"
    }
    if error is GMGNCLIError { return "gmgn_query_failed" }
    return "market_query_failed"
  }

  // MARK: - Trade automation

  func refreshTradeAutomationWorkspace() {
    Task { [weak self] in
      await self?.loadTradeAutomation()
    }
  }

  func refreshTradeIntent(_ source: TradeIntent) {
    guard let workspaceStore, let orderID = source.orderID, let chain = source.chain else {
      tradeAutomationError = "这条记录没有可查询的 GMGN 订单号。"
      return
    }
    Task { [weak self] in
      guard let self else { return }
      do {
        let snapshot = try await self.gmgnTradeClient.order(id: orderID, chain: chain)
        var intent = try await workspaceStore.tradeIntent(id: source.id) ?? source
        self.mergeTradeSnapshot(snapshot, into: &intent)
        intent.updatedAt = Date()
        _ = try await workspaceStore.updateTradeIntent(intent)
        await self.refreshTradeAutomationMetrics()
        self.tradeAutomationError = nil
      } catch {
        self.tradeAutomationError = "订单 \(orderID) 明细查询失败：\(error.localizedDescription)"
      }
    }
  }

  func updateTradeAutomationConfiguration(_ configuration: TradeAutomationConfiguration) {
    let normalized = configuration.normalized
    tradeAutomationConfiguration = normalized
    tradeSimulationResults = []
    tradeSimulationLastRunAt = nil
    guard let workspaceStore else { return }
    Task { [weak self] in
      do {
        self?.tradeAutomationConfiguration = try await workspaceStore
          .saveTradeAutomationConfiguration(normalized)
        self?.tradeAutomationError = nil
        await self?.refreshTradeAutomationMetrics()
      } catch {
        self?.tradeAutomationError = "无法保存交易设置：\(error.localizedDescription)"
      }
    }
  }

  func setTradeAutomationMode(_ mode: TradeAutomationMode) {
    var configuration = tradeAutomationConfiguration
    configuration.mode = mode
    updateTradeAutomationConfiguration(configuration)
  }

  func toggleTradeEmergencyStop() {
    var configuration = tradeAutomationConfiguration
    configuration.emergencyStopped.toggle()
    updateTradeAutomationConfiguration(configuration)
  }

  func saveTradeAutomationRule(_ rule: TradeAutomationRule) async throws {
    guard let workspaceStore else {
      throw WorkspaceStoreError.configurationFailed("workspace_store_unavailable")
    }
    let saved = try await workspaceStore.saveTradeAutomationRule(rule)
    if let index = tradeAutomationRules.firstIndex(where: { $0.id == saved.id }) {
      tradeAutomationRules[index] = saved
    } else {
      tradeAutomationRules.insert(saved, at: 0)
    }
    tradeAutomationRules.sort {
      if $0.isEnabled != $1.isEnabled { return $0.isEnabled }
      return $0.updatedAt > $1.updatedAt
    }
    tradeAutomationError = nil
    tradeSimulationResults = []
    tradeSimulationLastRunAt = nil
  }

  func setTradeAutomationRuleEnabled(_ rule: TradeAutomationRule, enabled: Bool) {
    var updated = rule
    updated.isEnabled = enabled
    updated.updatedAt = Date()
    Task { [weak self] in
      do {
        try await self?.saveTradeAutomationRule(updated)
      } catch {
        self?.tradeAutomationError = "无法更新交易规则：\(error.localizedDescription)"
      }
    }
  }

  /// Runs the rule engine against a deterministic local fixture. This is intentionally
  /// separate from signal handling so a user can validate a rule without creating a
  /// persisted intent or contacting a market provider.
  func runTradeAutomationSimulation() {
    let configuration = tradeAutomationConfiguration.normalized
    let rules = tradeAutomationRules.filter(\.isEnabled)
    tradeSimulationResults = rules.map {
      TradeAutomationSimulator.run(configuration: configuration, rule: $0)
    }
    tradeSimulationLastRunAt = Date()
  }

  func deleteTradeAutomationRule(_ rule: TradeAutomationRule) {
    guard let workspaceStore else { return }
    Task { [weak self] in
      do {
        try await workspaceStore.deleteTradeAutomationRule(id: rule.id)
        self?.tradeAutomationRules.removeAll { $0.id == rule.id }
        self?.tradeAutomationError = nil
      } catch {
        self?.tradeAutomationError = "无法删除交易规则：\(error.localizedDescription)"
      }
    }
  }

  func openTradeIntentSource(_ intent: TradeIntent) {
    guard let eventID = intent.sourceEventIDs.last, let messageStore else { return }
    Task { [weak self] in
      do {
        guard let event = try await messageStore.messages(eventIDs: [eventID]).first?.event else {
          self?.tradeAutomationError = "原始消息已不在本地消息库中"
          return
        }
        self?.openMessageContext(for: event)
      } catch {
        self?.tradeAutomationError = "无法定位原始消息：\(error.localizedDescription)"
      }
    }
  }

  func openMemeMode(for intent: TradeIntent) {
    prepareMemeMode(address: intent.tokenAddress, suggestedChain: intent.chain)
  }

  private func loadTradeAutomation() async {
    guard let workspaceStore else { return }
    isRefreshingTradeAutomation = true
    defer { isRefreshingTradeAutomation = false }
    do {
      if let configuration = try await workspaceStore.tradeAutomationConfiguration() {
        tradeAutomationConfiguration = configuration
      } else {
        tradeAutomationConfiguration = try await workspaceStore.saveTradeAutomationConfiguration(
          tradeAutomationConfiguration
        )
      }
      var rules = try await workspaceStore.tradeAutomationRules()
      if rules.isEmpty {
        rules = [try await workspaceStore.saveTradeAutomationRule(TradeAutomationRule())]
      }
      tradeAutomationRules = rules
      tradeIntents = try await workspaceStore.tradeIntents(limit: 300)
      tradeAutomationMetrics = try await workspaceStore.tradeAutomationMetrics()
      gmgnTradeConfigurationState = await gmgnTradeClient.configurationState()
      await reconcilePendingTradeIntents()
      tradeAutomationError = nil
    } catch {
      tradeAutomationError = "无法载入交易自动化：\(error.localizedDescription)"
    }
  }

  private func refreshTradeAutomationMetrics() async {
    guard let workspaceStore else { return }
    do {
      tradeAutomationMetrics = try await workspaceStore.tradeAutomationMetrics()
      tradeIntents = try await workspaceStore.tradeIntents(limit: 300)
    } catch {
      tradeAutomationError = "无法刷新交易审计：\(error.localizedDescription)"
    }
  }

  /// Re-queries persisted orders after launch. Intents without an order ID remain
  /// visible as pending and require manual reconciliation because the CLI may have
  /// been interrupted before it returned an order identifier.
  private func reconcilePendingTradeIntents() async {
    guard let workspaceStore else { return }
    for var intent in tradeIntents where intent.state == .submitting && intent.orderID == nil {
      if intent.failureReason == nil {
        intent.failureReason = "上次提交未返回订单 ID，结果待人工核对；请勿直接重复交易。"
        intent.updatedAt = Date()
        _ = try? await workspaceStore.updateTradeIntent(intent)
      }
    }
    let pending = tradeIntents.filter {
      ($0.state == .pending || $0.state == .submitting)
        && $0.orderID != nil
        && $0.chain != nil
    }
    for var intent in pending {
      guard let orderID = intent.orderID, let chain = intent.chain else { continue }
      do {
        let snapshot = try await gmgnTradeClient.order(id: orderID, chain: chain)
        mergeTradeSnapshot(snapshot, into: &intent)
        intent.updatedAt = Date()
        _ = try await workspaceStore.updateTradeIntent(intent)
      } catch {
        tradeAutomationError = "订单 \(orderID) 状态查询失败：\(error.localizedDescription)"
      }
    }
    let incompleteReceipts = tradeIntents.filter {
      $0.state == .confirmed && $0.orderID != nil && $0.chain != nil
        && ($0.executionReport == nil || $0.confirmedAt == nil)
    }.prefix(5)
    for var intent in incompleteReceipts {
      guard let orderID = intent.orderID, let chain = intent.chain else { continue }
      guard let snapshot = try? await gmgnTradeClient.order(id: orderID, chain: chain),
        snapshot.isConfirmed
      else { continue }
      intent.transactionHash = snapshot.transactionHash ?? intent.transactionHash
      intent.strategyOrderID = snapshot.strategyOrderID ?? intent.strategyOrderID
      intent.executionReport = snapshot.report ?? intent.executionReport
      intent.confirmedAt = intent.confirmedAt ?? snapshot.fetchedAt
      intent.updatedAt = Date()
      _ = try? await workspaceStore.updateTradeIntent(intent)
    }
    await refreshTradeAutomationMetrics()
  }

  private func scheduleTradeAutomationEvaluation(
    matches: [CryptoAddressMatch],
    event: MessageEvent
  ) {
    guard tradeAutomationConfiguration.mode != .off,
      !tradeAutomationConfiguration.emergencyStopped,
      tradeAutomationRules.contains(where: \.isEnabled)
    else { return }
    var seen = Set<String>()
    for match in matches where seen.insert(match.id).inserted {
      tradeAutomationTasks[match.id]?.cancel()
      tradeAutomationTasks[match.id] = Task { [weak self] in
        do {
          try await Task.sleep(for: .milliseconds(450))
          guard let self else { return }
          await self.evaluateTradeAutomation(match: match, event: event)
          self.tradeAutomationTasks[match.id] = nil
        } catch {
          self?.tradeAutomationTasks[match.id] = nil
        }
      }
    }
  }

  private func evaluateTradeAutomation(
    match: CryptoAddressMatch,
    event: MessageEvent
  ) async {
    guard let workspaceStore else { return }
    let configuration = tradeAutomationConfiguration.normalized
    let rules = tradeAutomationRules.filter(\.isEnabled)
    guard configuration.mode != .off, !configuration.emergencyStopped, !rules.isEmpty else {
      return
    }
    let end = max(Date(), event.observedAt).addingTimeInterval(0.001)

    struct Candidate {
      let rule: TradeAutomationRule
      let summary: CryptoAddressMentionSummary
    }
    var candidates: [Candidate] = []
    do {
      for rule in rules {
        if let summary = try await workspaceStore.cryptoAddressMentionSummary(
          family: match.family,
          network: match.network,
          normalizedAddress: match.normalizedAddress,
          start: end.addingTimeInterval(-rule.normalized.aggregationWindowSeconds),
          end: end
        ), summary.mentionCount >= rule.normalized.minimumMentions,
          summary.groupNames.count >= rule.normalized.minimumDistinctGroups
        {
          candidates.append(Candidate(rule: rule.normalized, summary: summary))
        }
      }
    } catch {
      tradeAutomationError = "交易信号聚合失败：\(error.localizedDescription)"
      return
    }
    guard !candidates.isEmpty else { return }

    let chain: GMGNChain?
    do {
      chain = try await resolvedTradeChain(for: match)
    } catch {
      chain = nil
    }

    let report: GMGNTokenReport?
    if let chain {
      report = try? await gmgnClient.tokenReport(
        chain: chain,
        address: match.normalizedAddress
      )
    } else {
      report = nil
    }

    for candidate in candidates {
      guard !Task.isCancelled else { return }
      let now = Date()
      let dayStart = Calendar.current.startOfDay(for: now)
      let metrics = (try? await workspaceStore.tradeAutomationMetrics(now: now))
        ?? tradeAutomationMetrics
      let ruleDailyCount = (try? await workspaceStore.tradeIntentCount(
        ruleID: candidate.rule.id,
        since: dayStart
      )) ?? 0
      let lastTokenIntent = try? await workspaceStore.latestTradeIntentDate(
        family: match.family,
        chain: chain,
        tokenAddress: match.normalizedAddress
      )
      let market = report.map {
        CATokenMarketSnapshot(token: $0.token, capturedAt: $0.fetchedAt)
      } ?? caWatchPoolItem(for: match)?.currentSnapshot
      let decision = TradeRiskEngine.evaluate(
        TradeRiskContext(
          configuration: configuration,
          rule: candidate.rule,
          family: match.family,
          chain: chain,
          triggeringGroup: event.group,
          triggeringSender: event.senderDisplayName,
          mentionCount: candidate.summary.mentionCount,
          distinctGroupCount: candidate.summary.groupNames.count,
          groupNames: candidate.summary.groupNames,
          market: market,
          security: report?.security,
          holderCount: report?.token.holderCount,
          dailyIntentCount: metrics.dailyIntentCount,
          ruleDailyIntentCount: ruleDailyCount,
          openPositionCount: metrics.openPositionCount,
          consecutiveFailureCount: metrics.consecutiveFailureCount,
          currentDailySpendUSD: metrics.dailyEstimatedSpendUSD,
          lastIntentForTokenAt: lastTokenIntent,
          now: now
        )
      )
      let window = candidate.rule.aggregationWindowSeconds
      let bucket = floor(event.observedAt.timeIntervalSince1970 / window) * window
      let key = TradeIntent.idempotencyKey(
        ruleID: candidate.rule.id,
        family: match.family,
        chain: chain,
        address: match.normalizedAddress,
        windowStart: Date(timeIntervalSince1970: bucket)
      )
      let inputToken = chain.flatMap(GMGNNativeAsset.address(for:))
      let inputAmount = chain.flatMap {
        GMGNNativeAsset.smallestUnitAmount(candidate.rule.inputAmountNative, chain: $0)
      }
      var intent = TradeIntent(
        idempotencyKey: key,
        ruleID: candidate.rule.id,
        state: decision.isEligible ? .eligible : .rejected,
        chain: chain,
        family: match.family,
        tokenAddress: match.normalizedAddress,
        tokenSymbol: report?.token.symbol ?? market?.symbol,
        tokenName: report?.token.name ?? market?.name,
        tokenLogoURL: report?.token.logoURL ?? market?.logoURL,
        sourceEventIDs: [event.eventID],
        sourceGroups: candidate.summary.groupNames,
        mentionCount: candidate.summary.mentionCount,
        distinctGroupCount: candidate.summary.groupNames.count,
        marketSnapshot: market,
        securitySnapshot: report?.security,
        inputToken: inputToken,
        outputToken: match.normalizedAddress,
        inputAmountNative: candidate.rule.inputAmountNative,
        inputAmountSmallestUnit: inputAmount,
        rejectionReasons: decision.reasons,
        createdAt: now,
        updatedAt: now
      )

      do {
        let inserted = try await workspaceStore.insertTradeIntent(intent)
        guard inserted.id == intent.id else { continue }
        if decision.isEligible {
          switch configuration.mode {
          case .off:
            intent.state = .rejected
            intent.rejectionReasons = ["交易自动化已关闭"]
          case .simulation:
            intent.state = .simulated
          case .approvalRequired:
            intent = await prepareTradeIntentQuote(
              intent,
              rule: candidate.rule,
              configuration: configuration
            )
          }
          intent.updatedAt = Date()
          _ = try await workspaceStore.updateTradeIntent(intent)
        }
      } catch {
        tradeAutomationError = "无法记录交易意图：\(error.localizedDescription)"
      }
    }
    await refreshTradeAutomationMetrics()
  }

  private func resolvedTradeChain(for match: CryptoAddressMatch) async throws -> GMGNChain {
    if match.family == .solana { return .sol }
    switch match.network {
    case .ethereum: return .eth
    case .base: return .base
    case .bsc: return .bsc
    case .robinhood: return .robinhood
    default: break
    }
    do {
      let matches = try await gmgnClient.identifyEVMToken(address: match.normalizedAddress)
      if matches.count == 1, let chain = matches.first?.chain { return chain }
      if !matches.isEmpty { throw CAWatchPoolRuntimeError.chainUnresolved }
    } catch let error as CAWatchPoolRuntimeError {
      throw error
    } catch {
      // DexScreener remains the fallback when GMGN has no usable response.
    }
    let resolution = try await resolveEVMChain(address: match.normalizedAddress)
    guard let chain = resolution.selectedChain else {
      throw CAWatchPoolRuntimeError.chainUnresolved
    }
    return chain
  }

  private func mergeTradeSnapshot(
    _ snapshot: GMGNTradeOrderSnapshot,
    into intent: inout TradeIntent
  ) {
    if !snapshot.orderID.isEmpty { intent.orderID = snapshot.orderID }
    intent.transactionHash = snapshot.transactionHash ?? intent.transactionHash
    intent.strategyOrderID = snapshot.strategyOrderID ?? intent.strategyOrderID
    intent.executionReport = snapshot.report ?? intent.executionReport
    switch snapshot.status.lowercased() {
    case "confirmed", "successful", "success":
      intent.state = .confirmed
      intent.failureReason = nil
      intent.confirmedAt = snapshot.fetchedAt
    case "failed", "expired":
      intent.state = .failed
      intent.failureReason = snapshot.errorStatus ?? snapshot.errorCode
        ?? "GMGN 订单 \(snapshot.status.lowercased())"
    default:
      intent.state = intent.orderID == nil ? .submitting : .pending
      intent.failureReason = snapshot.errorStatus ?? snapshot.errorCode
    }
  }

  private func prepareTradeIntentQuote(
    _ source: TradeIntent,
    rule: TradeAutomationRule,
    configuration: TradeAutomationConfiguration
  ) async -> TradeIntent {
    var intent = source
    guard let chain = intent.chain,
      let inputToken = intent.inputToken,
      let inputAmount = intent.inputAmountSmallestUnit
    else {
      intent.state = .rejected
      intent.rejectionReasons = ["实盘待确认模式需要配置钱包公钥和明确网络"]
      return intent
    }
    guard let wallet = await resolvedWalletAddress(for: chain) else {
      intent.state = .rejected
      intent.rejectionReasons = ["当前 GMGN API Key 未返回该网络的钱包"]
      return intent
    }
    do {
      intent.quote = try await gmgnTradeClient.quote(
        GMGNTradeQuoteRequest(
          chain: chain,
          walletAddress: wallet,
          inputToken: inputToken,
          outputToken: intent.tokenAddress,
          inputAmountSmallestUnit: inputAmount,
          slippagePercent: rule.maximumSlippagePercent
        )
      )
      intent.state = .awaitingConfirmation
    } catch {
      intent.state = .failed
      intent.failureReason = error.localizedDescription
    }
    return intent
  }

  private func formattedCAThreshold(_ value: Double) -> String {
    if value >= 1_000_000 {
      return "$" + (value / 1_000_000).formatted(
        .number.precision(.fractionLength(0...1))
      ) + "M"
    }
    if value >= 1_000 {
      return "$" + (value / 1_000).formatted(
        .number.precision(.fractionLength(0...1))
      ) + "K"
    }
    return value.formatted(.currency(code: "USD").precision(.fractionLength(0)))
  }

  var notificationDiagnosticText: String {
    guard let health = notificationHealth else {
      return isListening ? "正在建立通知数据库基线。" : "启动监听后显示分层诊断。"
    }
    if let error = health.lastError {
      return "通知数据库读取失败，正在自动重试：\(error)"
    }
    switch health.latestActivity {
    case .waitingForNewRecords:
      return "基线后尚未发现新的系统通知。请用另一台设备或其他群友发送测试消息。"
    case .nonWeChatNotifications:
      return "系统通知数据库有新增记录，但其中没有企业微信通知。请检查企业微信和 macOS 通知设置。"
    case .payloadDecodeFailed:
      return "发现了企业微信通知，但当前版本的通知 payload 未能解码。"
    case .groupNotMonitored:
      return "企业微信通知已成功解码，但群名或群聊结构未命中监听规则。请核对完整群名。"
    case .matchedGroup:
      if !messages.isEmpty, visibleMessages.isEmpty {
        return "群通知已进入 wxFomo，但被当前视图、搜索或筛选条件隐藏。"
      }
      return "群名已命中，通知事件已进入 wxFomo。"
    }
  }

  var activeFilterCount: Int {
    var count = 0
    if !parsedTerms(includeKeywords).isEmpty { count += 1 }
    if !parsedTerms(excludeKeywords).isEmpty { count += 1 }
    if onlyMentions { count += 1 }
    if onlyKnownSenders { count += 1 }
    if kindFilter != .all { count += 1 }
    if addressFilter != .all { count += 1 }
    if focusedAddress != nil { count += 1 }
    return count
  }

  var canMarkCurrentMessagesReviewed: Bool {
    guard messageContextFocus == nil else { return false }
    let coversReviewHighWatermark = timePreset == .sinceLastReview || timePreset == .all
    guard coversReviewHighWatermark,
      workspaceSelection != .captured,
      searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      activeFilterCount == 0,
      !hasMoreMessages
    else {
      return false
    }
    return !visibleMessages.isEmpty
  }

  func isCaptured(_ event: MessageEvent) -> Bool {
    if suppressedEventIDs.contains(event.eventID) { return false }
    if capturedEventIDs.contains(event.eventID) { return true }
    let terms = parsedTerms(captureKeywords)
    guard !terms.isEmpty else { return false }
    return terms.contains { term in
      searchableValues(event).contains { $0.localizedCaseInsensitiveContains(term) }
    }
  }

  func resetFilters() {
    includeKeywords = ""
    excludeKeywords = ""
    onlyMentions = false
    onlyKnownSenders = false
    kindFilter = .all
    addressFilter = .all
    focusedAddress = nil
  }

  func setAddressFilter(_ filter: AddressFilter) {
    focusedAddress = nil
    addressFilter = filter
  }

  func focusMessages(matching match: CryptoAddressMatch) {
    addressFilter = .all
    focusedAddress = match
  }

  func clearAddressFocus() {
    focusedAddress = nil
  }

  func openMessageContext(for event: MessageEvent) {
    let returnState = messageContextFocus
    messageContextFocus = MessageContextFocus(
      eventID: event.eventID,
      group: event.group,
      observedAt: event.observedAt,
      beforeMessageLimit: 30,
      afterMessageLimit: 30,
      returnSelection: returnState?.returnSelection ?? workspaceSelection,
      returnTimePreset: returnState?.returnTimePreset ?? timePreset,
      returnCustomStart: returnState?.returnCustomStart ?? customRangeStart,
      returnCustomEnd: returnState?.returnCustomEnd ?? customRangeEnd
    )
    workspaceSelection = .group(event.group)
    scheduleMessageReload()
  }

  func closeMessageContext() {
    guard let focus = messageContextFocus else { return }
    messageContextFocus = nil
    workspaceSelection = focus.returnSelection
    timePreset = focus.returnTimePreset
    customRangeStart = focus.returnCustomStart
    customRangeEnd = focus.returnCustomEnd
    scheduleMessageReload()
  }

  func workspaceSelectionDidChange() {
    if let focus = messageContextFocus,
      workspaceSelection != .group(focus.group)
    {
      messageContextFocus = nil
    }
    if workspaceSelection.isMessageFeed {
      scheduleMessageReload()
    }
  }

  func addressMatches(for event: MessageEvent) -> [CryptoAddressMatch] {
    let rawMatches: [CryptoAddressMatch]
    if let cached = addressMatchesCache[event.eventID] {
      rawMatches = cached
    } else {
      rawMatches = CryptoAddressDetector.matches(in: event.content)
      addressMatchesCache[event.eventID] = rawMatches
    }
    return rawMatches.map { match in
      if match.family == .solana {
        return match.resolvingNetwork(.solana)
      }
      guard let snapshot = caTokenSnapshot(eventID: event.eventID, match: match) else {
        return match
      }
      return match.resolvingNetwork(snapshot.chain.cryptoAddressNetwork)
    }
  }

  func webLinks(for event: MessageEvent) -> [WebLinkMatch] {
    if let cached = webLinksCache[event.eventID] { return cached }
    let matches = WebLinkDetector.matches(in: event.content)
    webLinksCache[event.eventID] = matches
    return matches
  }

  private func invalidatePresentationCaches() {
    addressMatchesCache.removeAll(keepingCapacity: true)
    webLinksCache.removeAll(keepingCapacity: true)
  }

  func addGroup() {
    let candidate = groupDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty else { return }
    if !groups.contains(candidate) {
      groups.append(candidate)
      persistGroups()
      refreshHistoryDiagnostic()
      scheduleAddressBackfill()
    }
    workspaceSelection = .group(candidate)
    groupDraft = ""
    if case .idle = listenerState {
      activityText = "已添加 \(candidate)"
    }
    scheduleMessageReload()
  }

  func removeGroup(_ group: String) {
    guard !isListening else { return }
    groups.removeAll { $0 == group }
    if workspaceSelection == .group(group) {
      workspaceSelection = groups.first.map(WorkspaceSelection.group) ?? .inbox
    }
    persistGroups()
    refreshHistoryDiagnostic()
    activityText = groups.isEmpty ? "添加群聊后即可开始" : "已移除 \(group)"
    scheduleMessageReload()
  }

  func clearMessages() {
    messages.removeAll()
    rangeStatistics = nil
    flowAnalytics = nil
    previousFlowAnalytics = nil
    managementMetrics = nil
    activityText = isListening ? "已隐藏当前列表，消息仍保存在本机" : "已隐藏当前列表，消息仍保存在本机"
  }

  func setSoundEnabled(_ isEnabled: Bool) {
    updateSoundConfiguration { $0.isEnabled = isEnabled }
  }

  func setSoundMasterVolume(_ volume: Double) {
    updateSoundConfiguration { $0.masterVolume = volume }
  }

  func setSoundPlayWhileActive(_ isEnabled: Bool) {
    updateSoundConfiguration { $0.playWhileAppIsActive = isEnabled }
  }

  func setSoundMinimumInterval(_ interval: TimeInterval) {
    updateSoundConfiguration { $0.minimumInterval = interval }
  }

  @discardableResult
  func saveSpeechServiceConfiguration(
    _ configuration: NotificationSpeechConfiguration,
    apiKey: String = ""
  ) -> Bool {
    do {
      let enteredAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      try credentialStore.storeSpeechConfiguration(
        configuration,
        updatingAPIKey: enteredAPIKey.isEmpty ? nil : enteredAPIKey
      )
      var updated = soundConfiguration
      updated.speech = configuration.normalized
      soundConfiguration = updated
      if !enteredAPIKey.isEmpty {
        isSpeechAPIKeyConfigured = true
      }
      soundStatusText = "语音服务配置已保存"
      return true
    } catch {
      soundStatusText = error.localizedDescription
      return false
    }
  }

  func deleteSpeechAPIKey() {
    do {
      try credentialStore.deleteSpeechAPIKey()
      isSpeechAPIKeyConfigured = false
      soundStatusText = "已清空火山语音 API Key"
    } catch {
      soundStatusText = error.localizedDescription
    }
  }

  func muteSounds(for interval: TimeInterval) {
    updateSoundConfiguration { configuration in
      configuration.mutedUntil = interval > 0 ? Date().addingTimeInterval(interval) : nil
    }
  }

  func saveSoundRule(_ rule: NotificationSoundRule) {
    let normalized = rule.normalized
    updateSoundConfiguration { configuration in
      if let index = configuration.rules.firstIndex(where: { $0.id == normalized.id }) {
        configuration.rules[index] = normalized
      } else {
        configuration.rules.append(normalized)
      }
    }
  }

  func setSoundRuleEnabled(_ rule: NotificationSoundRule, isEnabled: Bool) {
    var updated = rule
    updated.isEnabled = isEnabled
    saveSoundRule(updated)
  }

  func deleteSoundRule(_ rule: NotificationSoundRule) {
    updateSoundConfiguration { configuration in
      configuration.rules.removeAll { $0.id == rule.id }
    }
  }

  func resetSoundConfiguration() {
    soundConfiguration = NotificationSoundConfiguration()
    persistSoundConfiguration()
    soundStatusText = "已恢复默认提醒规则"
  }

  func previewSoundRule(_ rule: NotificationSoundRule) {
    soundStatusText = rule.effectiveOutputMode.includesSpeech ? "正在准备播报" : "正在试听"
    let didPlay = soundController.preview(
      rule: rule,
      configuration: soundConfiguration,
      speechAPIKey: try? credentialStore.speechAPIKey()
    ) { [weak self] status in
      self?.soundStatusText = status
    }
    if !didPlay {
      soundStatusText = "当前提醒无法播放"
    }
  }

  func previewConfiguredSpeech() {
    previewSoundRule(
      NotificationSoundRule(
        id: "configuration-center.speech-preview",
        name: "语音试听",
        eventKind: .cryptoAddress,
        outputMode: .speech,
        soundName: "Pop",
        speechAnnouncement: NotificationSpeechAnnouncement(text: "魅力苏菲语音配置成功")
      )
    )
  }

  private func updateSoundConfiguration(
    _ update: (inout NotificationSoundConfiguration) -> Void
  ) {
    var configuration = soundConfiguration
    update(&configuration)
    soundConfiguration = configuration.normalized
    persistSoundConfiguration()
  }

  private func persistSoundConfiguration() {
    guard let data = try? JSONEncoder().encode(soundConfiguration) else {
      soundStatusText = "无法保存音效设置"
      return
    }
    UserDefaults.standard.set(data, forKey: soundConfigurationDefaultsKey)
  }

  func scheduleMessageReload() {
    messageLoadTask?.cancel()
    messageLoadTask = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled else { return }
      await self.reloadMessages()
    }
  }

  func reloadMessages() async {
    guard let messageStore else {
      messageStoreError = messageStoreError ?? "本地消息库不可用"
      return
    }

    isLoadingMessages = true
    defer { isLoadingMessages = false }
    do {
      try await ensureSystemTags(in: messageStore)
      if let focus = messageContextFocus {
        let contextMessages = try await messageStore.messages(
          aroundEventID: focus.eventID,
          beforeLimit: focus.beforeMessageLimit,
          afterLimit: focus.afterMessageLimit
        )
        guard !Task.isCancelled, messageContextFocus?.eventID == focus.eventID else {
          return
        }
        messages = contextMessages.map(\.event)
        invalidatePresentationCaches()
        if let workspaceStore {
          let enrichments = try await workspaceStore.caSignalEnrichments(
            eventIDs: contextMessages.map(\.event.eventID)
          )
          mergeCASignalEnrichments(enrichments)
        }
        updateSystemTagMembership(from: contextMessages, replacing: true)
        nextPageCursor = nil
        hasMoreMessages = false
        rangeStatistics = nil
        flowAnalytics = nil
        previousFlowAnalytics = nil
        managementMetrics = nil
        messageStoreError = nil
        return
      }
      let scope = try await currentMessageScope(store: messageStore)
      let page = try await messageStore.messages(
        matching: MessageQuery(
          scope: scope,
          limit: messagePageSize,
          order: .newestFirst
        )
      )
      guard !Task.isCancelled else { return }
      messages = page.messages.map(\.event).sorted(by: MessageEventOrder.latestFirst)
      invalidatePresentationCaches()
      if let workspaceStore {
        let enrichments = try await workspaceStore.caSignalEnrichments(
          eventIDs: page.messages.map(\.event.eventID)
        )
        mergeCASignalEnrichments(enrichments)
      }
      updateSystemTagMembership(from: page.messages, replacing: true)
      nextPageCursor = page.nextCursor
      hasMoreMessages = page.hasMore
      let analytics = try await messageStore.flowAnalytics(in: scope)
      let previousAnalytics = try await previousFlowAnalytics(for: scope, store: messageStore)
      let managementInputs = try await managementMetricInputs(for: scope, store: messageStore)
      let management = try await messageStore.managementMetrics(
        baseScope: managementInputs.baseScope,
        priorityMatch: managementInputs.priorityMatch,
        suppressedTagIDs: managementInputs.suppressedTagIDs,
        reviewCursors: managementInputs.reviewCursors
      )
      flowAnalytics = analytics
      previousFlowAnalytics = previousAnalytics
      managementMetrics = management
      rangeStatistics = analytics.statistics
      capturedTotalCount = try await messageStore.statistics(
        in: globalCapturedScope()
      ).capturedCount
      messageStoreError = nil
    } catch is CancellationError {
      return
    } catch {
      messageStoreError = error.localizedDescription
    }
  }

  func loadMoreMessages() {
    guard let messageStore, let cursor = nextPageCursor, !isLoadingMessages else { return }
    messageLoadTask?.cancel()
    messageLoadTask = Task { [weak self] in
      guard let self else { return }
      self.isLoadingMessages = true
      defer { self.isLoadingMessages = false }
      do {
        let scope = try await self.currentMessageScope(store: messageStore)
        let page = try await messageStore.messages(
          matching: MessageQuery(
            scope: scope,
            limit: self.messagePageSize,
            after: cursor,
            order: .newestFirst
          )
        )
        guard !Task.isCancelled else { return }
        let combined = self.messages + page.messages.map(\.event)
        self.messages = Dictionary(grouping: combined, by: \.eventID)
          .compactMap { $0.value.first }
          .sorted(by: MessageEventOrder.latestFirst)
        self.invalidatePresentationCaches()
        if let workspaceStore = self.workspaceStore {
          let enrichments = try await workspaceStore.caSignalEnrichments(
            eventIDs: page.messages.map(\.event.eventID)
          )
          self.mergeCASignalEnrichments(enrichments)
        }
        self.updateSystemTagMembership(from: page.messages, replacing: false)
        self.nextPageCursor = page.nextCursor
        self.hasMoreMessages = page.hasMore
      } catch is CancellationError {
        return
      } catch {
        self.messageStoreError = error.localizedDescription
      }
    }
  }

  func markCurrentMessagesReviewed() {
    guard canMarkCurrentMessagesReviewed, let messageStore else { return }
    let latestByGroup = Dictionary(grouping: visibleMessages, by: \.group)
      .compactMapValues { $0.max(by: MessageEventOrder.precedes) }
    guard !latestByGroup.isEmpty else { return }

    Task { [weak self] in
      do {
        for (group, event) in latestByGroup {
          _ = try await messageStore.setReviewCursor(group: group, eventID: event.eventID)
        }
        guard let self else { return }
        self.activityText = "已记录 \(latestByGroup.count) 个群聊的查看位置"
        if self.timePreset == .sinceLastReview {
          await self.reloadMessages()
        }
      } catch {
        self?.messageStoreError = error.localizedDescription
      }
    }
  }

  func setAutomationEnabled(_ isEnabled: Bool) {
    automationEnabled = isEnabled
    UserDefaults.standard.set(isEnabled, forKey: "wxfomo.automation.enabled")
    if isEnabled {
      startAutomation()
    } else {
      stopAutomation()
    }
  }

  func refreshAutomationStatus() {
    guard let automationBroadcaster else { return }
    Task { [weak self] in
      self?.automationStatus = await automationBroadcaster.status()
    }
  }

  func reloadWorkspace() async {
    guard let workspaceStore else {
      workspaceStoreError = workspaceStoreError ?? "工作区数据库不可用"
      return
    }
    do {
      async let providers = workspaceStore.providerConfigurations()
      async let defaultProvider = workspaceStore.defaultProviderConfiguration()
      async let rules = workspaceStore.messageRules()
      async let jobs = workspaceStore.analysisJobs(limit: 200)
      async let results = workspaceStore.analysisResults(limit: 200)
      async let alerts = workspaceStore.alerts(includeAcknowledged: true, limit: 200)
      async let addressIncidents = workspaceStore.crossGroupAddressIncidents(limit: 500)
      async let unacknowledgedAlerts = workspaceStore.alerts(
        includeAcknowledged: false,
        limit: 500
      )
      providerConfigurations = try await providers
      let providerIDs = Set(providerConfigurations.map(\.configurationID))
      providerConnectionTests = providerConnectionTests.filter { providerIDs.contains($0.key) }
      testingProviderIDs.formIntersection(providerIDs)
      defaultProviderID = try await defaultProvider?.configurationID
      messageRules = try await rules
      analysisJobs = try await jobs
      let loadedResults = try await results
      let loadedResultIDs = Set(loadedResults.map(\.result.analysisID))
      let completedResultIDs = didSeedAnalysisSoundBaseline
        ? loadedResultIDs.subtracting(knownAnalysisResultIDs)
        : []
      analysisResults = loadedResults
      knownAnalysisResultIDs = loadedResultIDs
      didSeedAnalysisSoundBaseline = true
      if !completedResultIDs.isEmpty {
        playNotificationSounds(
          completedResultIDs.sorted().map { analysisID in
            NotificationSoundEvent(
              kind: .analysisCompleted,
              eventID: analysisID,
              subjectID: analysisID
            )
          }
        )
      }
      if let messageStore {
        let ranges = try await messageStore.frozenRanges(limit: 200)
        analysisRanges = Dictionary(uniqueKeysWithValues: ranges.map { ($0.id, $0) })
      } else {
        analysisRanges = [:]
      }
      let loadedAlerts = try await alerts
      crossGroupAddressIncidents = try await addressIncidents
      let loadedUnacknowledgedAlerts = try await unacknowledgedAlerts
      workspaceAlerts = combinedAlerts(
        recent: loadedAlerts,
        unacknowledged: loadedUnacknowledgedAlerts
      )
      unacknowledgedAlertCount = loadedUnacknowledgedAlerts.count
      unacknowledgedAlertCountIsCapped = loadedUnacknowledgedAlerts.count == 500
      try await cacheLoadedAlertSources()
      isProcessingAnalysisQueue = analysisJobs.contains { !$0.state.isTerminal }
      if selectedAnalysisID == nil {
        selectedAnalysisID = analysisResults.first?.result.analysisID
      }
      if let selectedAnalysisID {
        try await loadAnalysisSources(id: selectedAnalysisID)
      } else {
        loadedAnalysisSourceAnalysisID = nil
        replaceSelectedAnalysisSources([:])
      }
      workspaceStoreError = nil
    } catch {
      workspaceStoreError = error.localizedDescription
    }
  }

  func refreshAlerts() {
    Task { [weak self] in
      await self?.reloadAlerts()
    }
  }

  func acknowledgeAlert(_ alert: WorkspaceAlert) {
    guard !alert.isAcknowledged, let workspaceStore, !isUpdatingAlerts else { return }
    isUpdatingAlerts = true
    Task { [weak self] in
      guard let self else { return }
      defer { isUpdatingAlerts = false }
      do {
        _ = try await workspaceStore.acknowledgeAlert(id: alert.alertID)
        await reloadAlerts()
      } catch {
        workspaceStoreError = "无法确认提醒：\(error.localizedDescription)"
      }
    }
  }

  func acknowledgeAllAlerts() {
    guard let workspaceStore, !isUpdatingAlerts, unacknowledgedAlertCount > 0 else { return }
    isUpdatingAlerts = true
    Task { [weak self] in
      guard let self else { return }
      defer { isUpdatingAlerts = false }
      do {
        for _ in 0..<20 {
          let pending = try await workspaceStore.alerts(includeAcknowledged: false, limit: 500)
          guard !pending.isEmpty else { break }
          for alert in pending {
            _ = try await workspaceStore.acknowledgeAlert(id: alert.alertID)
          }
          if pending.count < 500 { break }
        }
        await reloadAlerts()
      } catch {
        workspaceStoreError = "无法确认全部提醒：\(error.localizedDescription)"
        await reloadAlerts()
      }
    }
  }

  func saveProvider(_ draft: ProviderDraft) async -> Bool {
    guard let workspaceStore else {
      workspaceStoreError = "工作区数据库不可用"
      return false
    }
    do {
      guard let baseURL = URL(string: draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
      else {
        throw AIProviderConfigurationError.missingBaseURL
      }
      let existing = draft.configurationID.flatMap { configurationID in
        providerConfigurations.first { $0.configurationID == configurationID }
      }
      let configurationID = existing?.configurationID ?? UUID().uuidString.lowercased()
      let configuration = try AIProviderConfiguration(
        configurationID: configurationID,
        displayName: draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
        kind: draft.kind,
        baseURL: baseURL,
        model: draft.model.trimmingCharacters(in: .whitespacesAndNewlines),
        credentialReference: existing?.credentialReference ?? configurationID
      )
      let enteredAPIKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      if !enteredAPIKey.isEmpty {
        try credentialStore.storeAPIKey(enteredAPIKey, for: configuration)
      } else if existing == nil {
        throw AICredentialStoreError.emptyAPIKey
      } else if credentialScopeChanged(from: existing!, to: configuration) {
        throw ProviderSaveError.apiKeyRequiredAfterEndpointChange
      } else if (try? credentialStore.apiKey(for: configuration)) == nil {
        throw ProviderSaveError.apiKeyRequired
      }
      do {
        _ = try await workspaceStore.saveProviderConfiguration(
          configuration,
          makeDefault: draft.makeDefault || providerConfigurations.isEmpty
        )
      } catch {
        if !enteredAPIKey.isEmpty, existing == nil {
          try? credentialStore.deleteAPIKey(for: configuration)
        }
        throw error
      }
      if let existing, !enteredAPIKey.isEmpty,
        credentialScopeChanged(from: existing, to: configuration)
      {
        try? credentialStore.deleteAPIKey(for: existing)
      }
      await reloadWorkspace()
      return true
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      workspaceStoreError = "无法保存 AI 模型服务：\(message)"
      return false
    }
  }

  private func credentialScopeChanged(
    from old: AIProviderConfiguration,
    to new: AIProviderConfiguration
  ) -> Bool {
    guard old.kind == new.kind,
      let oldComponents = URLComponents(url: old.baseURL, resolvingAgainstBaseURL: false),
      let newComponents = URLComponents(url: new.baseURL, resolvingAgainstBaseURL: false)
    else {
      return true
    }
    return oldComponents.scheme?.lowercased() != newComponents.scheme?.lowercased()
      || oldComponents.host?.lowercased() != newComponents.host?.lowercased()
      || oldComponents.port != newComponents.port
  }

  func setDefaultProvider(_ configuration: AIProviderConfiguration) {
    guard let workspaceStore else { return }
    Task { [weak self] in
      do {
        try await workspaceStore.setDefaultProviderConfiguration(id: configuration.configurationID)
        await self?.reloadWorkspace()
      } catch {
        self?.workspaceStoreError = error.localizedDescription
      }
    }
  }

  func testProviderConnection(_ configuration: AIProviderConfiguration) {
    let configurationID = configuration.configurationID
    guard testingProviderIDs.insert(configurationID).inserted else { return }
    Task { [weak self] in
      guard let self else { return }
      let tester = AIProviderConnectionTester(credentialStore: credentialStore)
      let result = await tester.test(configuration)
      providerConnectionTests[configurationID] = result
      testingProviderIDs.remove(configurationID)
    }
  }

  func deleteProvider(_ configuration: AIProviderConfiguration) {
    guard let workspaceStore else { return }
    Task { [weak self] in
      do {
        try await workspaceStore.deleteProviderConfiguration(id: configuration.configurationID)
        try self?.credentialStore.deleteAPIKey(for: configuration)
        self?.providerConnectionTests.removeValue(forKey: configuration.configurationID)
        self?.testingProviderIDs.remove(configuration.configurationID)
        await self?.reloadWorkspace()
      } catch {
        self?.workspaceStoreError = error.localizedDescription
      }
    }
  }

  func saveMessageRule(_ draft: MessageRuleDraft) async -> Bool {
    guard let workspaceStore else {
      workspaceStoreError = "工作区数据库不可用"
      return false
    }
    var actions: [MessageRuleAction] = []
    if draft.capture { actions.append(.capture) }
    if draft.suppress { actions.append(.suppress) }
    let tagName = draft.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !tagName.isEmpty { actions.append(.addTag(tagName)) }
    if let severity = draft.alertSeverity {
      actions.append(.localAlert(severity: severity, title: draft.name))
    }
    guard !actions.isEmpty else {
      workspaceStoreError = "规则至少需要一个动作"
      return false
    }

    let regexes = draft.regularExpressions
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let rule = MessageRule(
      id: UUID().uuidString.lowercased(),
      name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
      priority: draft.priority,
      isEnabled: draft.isEnabled,
      condition: MessageRuleCondition(
        groups: parsedTerms(draft.groups),
        senders: parsedTerms(draft.senders),
        includeKeywords: parsedTerms(draft.includeKeywords),
        excludeKeywords: parsedTerms(draft.excludeKeywords),
        regularExpressions: regexes
      ),
      actions: actions
    )
    let validationReasons = MessageRuleEngine.validationReasons(for: rule)
    guard validationReasons.isEmpty else {
      workspaceStoreError = "规则配置无效：\(validationReasons.map(\.code.rawValue).joined(separator: ", "))"
      return false
    }
    do {
      _ = try await workspaceStore.saveMessageRule(rule)
      await reloadWorkspace()
      return true
    } catch {
      workspaceStoreError = error.localizedDescription
      return false
    }
  }

  func installRecommendedMessageRules() async -> Int? {
    guard let workspaceStore else {
      workspaceStoreError = "工作区数据库不可用"
      return nil
    }
    do {
      let existingRules = try await workspaceStore.messageRules()
      var changedCount = 0
      for template in RecommendedMessageRuleCatalog.rules {
        let existing = existingRules.first { $0.name == template.name }
          ?? existingRules.first { $0.id == template.id }
        if let existing,
          existing.name == template.name,
          existing.priority == template.priority,
          existing.isEnabled == template.isEnabled,
          existing.condition == template.condition,
          existing.actions == template.actions
        {
          continue
        }
        let rule = MessageRule(
          schemaVersion: template.schemaVersion,
          revision: (existing?.revision ?? 0) + 1,
          id: existing?.id ?? template.id,
          name: template.name,
          priority: template.priority,
          isEnabled: template.isEnabled,
          condition: template.condition,
          actions: template.actions
        )
        let validationReasons = MessageRuleEngine.validationReasons(for: rule)
        guard validationReasons.isEmpty else {
          workspaceStoreError = "推荐规则无效：\(validationReasons.map(\.code.rawValue).joined(separator: ", "))"
          return nil
        }
        _ = try await workspaceStore.saveMessageRule(rule)
        changedCount += 1
      }
      await reloadWorkspace()
      activityText = changedCount == 0
        ? "推荐规则已是最新配置"
        : "已安装或更新 \(changedCount) 条推荐规则"
      return changedCount
    } catch {
      workspaceStoreError = "无法安装推荐规则：\(error.localizedDescription)"
      return nil
    }
  }

  func setMessageRuleEnabled(_ rule: MessageRule, isEnabled: Bool) {
    guard let workspaceStore else { return }
    let updated = MessageRule(
      schemaVersion: rule.schemaVersion,
      revision: rule.revision + 1,
      id: rule.id,
      name: rule.name,
      priority: rule.priority,
      isEnabled: isEnabled,
      condition: rule.condition,
      actions: rule.actions
    )
    Task { [weak self] in
      do {
        _ = try await workspaceStore.saveMessageRule(updated)
        await self?.reloadWorkspace()
      } catch {
        self?.workspaceStoreError = error.localizedDescription
      }
    }
  }

  func deleteMessageRule(_ rule: MessageRule) {
    guard let workspaceStore else { return }
    Task { [weak self] in
      do {
        try await workspaceStore.deleteMessageRule(id: rule.id)
        await self?.reloadWorkspace()
      } catch {
        self?.workspaceStoreError = error.localizedDescription
      }
    }
  }

  func enqueueAnalysis(
    mode: AIAnalysisMode,
    customInstructions: String?,
    providerID: String?,
    messages selectedEvents: [MessageEvent]
  ) async -> Bool {
    guard let messageStore, let workspaceStore else {
      workspaceStoreError = "消息或工作区数据库不可用"
      return false
    }
    guard let providerID = providerID ?? defaultProviderID else {
      workspaceStoreError = "请先选择一个 AI 服务"
      return false
    }
    guard !selectedEvents.isEmpty else {
      workspaceStoreError = "当前没有可分析的消息"
      return false
    }
    guard selectedEvents.count <= AIAnalysisRequest.maximumMessageCount else {
      workspaceStoreError = "单次最多分析 \(AIAnalysisRequest.maximumMessageCount) 条消息"
      return false
    }
    let instructions = customInstructions?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if mode == .custom, instructions?.isEmpty != false {
      workspaceStoreError = "自定义分析需要填写分析要求"
      return false
    }

    do {
      let scope = try await currentMessageScope(store: messageStore)
      let frozen = try await messageStore.freeze(
        eventIDs: selectedEvents.map(\.eventID),
        scope: scope
      )
      _ = try await workspaceStore.enqueueAnalysisJob(
        frozenRangeID: frozen.id,
        providerID: providerID,
        mode: mode,
        customInstructions: instructions?.isEmpty == true ? nil : instructions,
        idempotencyKey: "analysis:v1:\(frozen.id):\(providerID):\(mode.rawValue)"
      )
      workspaceStoreError = nil
      workspaceSelection = .analyses
      await reloadWorkspace()
      refreshAnalysisStatusUntilSettled()
      return true
    } catch {
      workspaceStoreError = "无法创建分析任务：\(error.localizedDescription)"
      return false
    }
  }

  func analysisStatistics(
    groups: Set<String>,
    range: MessageDateRange
  ) async throws -> MessageRangeStatistics {
    guard let messageStore else {
      throw AppModelAnalysisError.messageStoreUnavailable
    }
    let normalizedRange = range.normalized
    guard !groups.isEmpty else {
      throw AppModelAnalysisError.noGroupsSelected
    }
    return try await messageStore.statistics(
      in: MessageScope(
        groups: groups,
        startDate: normalizedRange.start,
        endDate: normalizedRange.end
      )
    )
  }

  func enqueueScopedAnalysis(
    mode: AIAnalysisMode,
    customInstructions: String? = nil,
    providerID: String?,
    groups: Set<String>,
    range: MessageDateRange
  ) async -> Bool {
    guard let messageStore, let workspaceStore else {
      workspaceStoreError = "消息或工作区数据库不可用"
      return false
    }
    guard let providerID = providerID ?? defaultProviderID else {
      workspaceStoreError = "请先选择一个 AI 服务"
      return false
    }
    guard !groups.isEmpty else {
      workspaceStoreError = "请至少选择一个群聊"
      return false
    }

    let normalizedRange = range.normalized
    let scope = MessageScope(
      groups: groups,
      startDate: normalizedRange.start,
      endDate: normalizedRange.end
    )
    let instructions = customInstructions?
      .trimmingCharacters(in: .whitespacesAndNewlines)

    do {
      let statistics = try await messageStore.statistics(in: scope)
      guard statistics.capturedCount > 0 else {
        workspaceStoreError = "所选群聊和时间区间内没有已采集消息"
        return false
      }
      guard statistics.capturedCount <= AIAnalysisRequest.maximumMessageCount else {
        workspaceStoreError =
          "所选范围有 \(statistics.capturedCount) 条消息，单次最多分析 \(AIAnalysisRequest.maximumMessageCount) 条；请缩短时间区间"
        return false
      }
      if mode == .custom, instructions?.isEmpty != false {
        workspaceStoreError = "自定义分析需要填写分析要求"
        return false
      }

      let frozen = try await messageStore.freeze(scope: scope)
      _ = try await workspaceStore.enqueueAnalysisJob(
        frozenRangeID: frozen.id,
        providerID: providerID,
        mode: mode,
        customInstructions: instructions?.isEmpty == true ? nil : instructions,
        idempotencyKey: "analysis:v1:\(frozen.id):\(providerID):\(mode.rawValue)"
      )
      workspaceStoreError = nil
      workspaceSelection = .analyses
      await reloadWorkspace()
      refreshAnalysisStatusUntilSettled()
      activityText = "已创建 \(groups.count) 个群、\(statistics.capturedCount) 条消息的分析任务"
      return true
    } catch {
      workspaceStoreError = "无法创建分析任务：\(error.localizedDescription)"
      return false
    }
  }

  func enqueueQuickAnalysis(
    mode: AIAnalysisMode = .digest,
    messages: [MessageEvent]
  ) async -> Bool {
    let providerID = defaultProviderID ?? providerConfigurations.first?.configurationID
    return await enqueueAnalysis(
      mode: mode,
      customInstructions: nil,
      providerID: providerID,
      messages: messages
    )
  }

  func selectAnalysis(_ analysisID: String) {
    selectedAnalysisID = analysisID
    Task { [weak self] in
      do {
        try await self?.loadAnalysisSources(id: analysisID)
      } catch {
        self?.workspaceStoreError = error.localizedDescription
      }
    }
  }

  func cancelAnalysisJob(_ job: AIAnalysisJob) {
    guard !job.state.isTerminal else { return }
    Task { [weak self] in
      guard let self else { return }
      do {
        if let analysisRunner {
          _ = try await analysisRunner.cancel(jobID: job.jobID)
        } else if let workspaceStore {
          _ = try await workspaceStore.cancel(jobID: job.jobID)
        }
        await reloadWorkspace()
      } catch {
        workspaceStoreError = error.localizedDescription
      }
    }
  }

  private func startAnalysisRunner() {
    guard analysisRunnerTask == nil, let analysisRunner else { return }
    analysisRunnerTask = Task { [weak self, analysisRunner] in
      do {
        try await analysisRunner.run()
      } catch is CancellationError {
        return
      } catch {
        self?.workspaceStoreError = "AI 分析队列已停止：\(error.localizedDescription)"
      }
    }
  }

  private func refreshAnalysisStatusUntilSettled() {
    analysisStatusRefreshTask?.cancel()
    analysisStatusRefreshTask = Task { [weak self] in
      for _ in 0..<600 {
        guard !Task.isCancelled, let self else { return }
        await self.reloadWorkspace()
        guard self.isProcessingAnalysisQueue else { return }
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func loadAnalysisSources(id analysisID: String) async throws {
    guard let messageStore,
      let stored = analysisResults.first(where: { $0.result.analysisID == analysisID })
    else {
      loadedAnalysisSourceAnalysisID = nil
      replaceSelectedAnalysisSources([:])
      return
    }
    if loadedAnalysisSourceAnalysisID == analysisID {
      return
    }
    let messages = try await messageStore.messages(inFrozenRange: stored.frozenRangeID)
    guard selectedAnalysisID == analysisID else { return }
    if let workspaceStore {
      let eventIDs = messages.map(\.event.eventID)
      for start in stride(from: 0, to: eventIDs.count, by: 500) {
        let end = min(start + 500, eventIDs.count)
        let enrichments = try await workspaceStore.caSignalEnrichments(
          eventIDs: Array(eventIDs[start..<end])
        )
        mergeCASignalEnrichments(enrichments)
      }
    }
    loadedAnalysisSourceAnalysisID = analysisID
    replaceSelectedAnalysisSources(
      Dictionary(uniqueKeysWithValues: messages.map { ($0.event.eventID, $0.event) })
    )
  }

  private func replaceSelectedAnalysisSources(_ messages: [String: MessageEvent]) {
    selectedAnalysisSourceMessages = messages
    selectedAnalysisSourceRevision &+= 1
  }

  private func startAutomation() {
    Task { [weak self] in
      guard let self else { return }
      do {
        let broadcaster: AutomationEventBroadcaster
        if let existing = self.automationBroadcaster {
          broadcaster = existing
        } else {
          let configuration = try AutomationEventBroadcasterConfiguration(
            endpoint: .applicationSupport
          )
          broadcaster = AutomationEventBroadcaster(configuration: configuration)
          self.automationBroadcaster = broadcaster
        }
        try await broadcaster.start()
        self.automationStatus = await broadcaster.status()
        self.automationError = nil
      } catch {
        self.automationError = error.localizedDescription
        if let broadcaster = self.automationBroadcaster {
          self.automationStatus = await broadcaster.status()
        }
      }
    }
  }

  private func stopAutomation() {
    guard let automationBroadcaster else {
      automationStatus = nil
      automationError = nil
      return
    }
    Task { [weak self] in
      await automationBroadcaster.stop()
      self?.automationStatus = await automationBroadcaster.status()
      self?.automationError = nil
    }
  }

  func toggleListening() {
    isListening ? stopListening() : startListening()
  }

  func startListening() {
    if !groupDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      addGroup()
    }
    guard !groups.isEmpty else {
      listenerState = .failed("请至少添加一个群聊")
      activityText = "没有可监听的群聊"
      return
    }
    let notificationReader = NotificationDatabaseReader()
    switch notificationReader.availability() {
    case .permissionDenied:
      refreshStatus()
      listenerState = .failed("需要完全磁盘访问权限")
      activityText = "通知数据库被系统拒绝读取；请点击左侧“完全磁盘访问”按钮授权后完全重启 App"
      playListenerIssue(subjectID: "notification-permission")
      return
    case .missingFile:
      refreshStatus()
      listenerState = .failed("通知数据库文件不存在")
      activityText = "找不到 macOS 通知数据库，请确认系统通知中心可用"
      playListenerIssue(subjectID: "notification-database-missing")
      return
    case .readable, .unreadable:
      break
    }

    let monitoredGroups = groups
    let shouldIncludeExisting = includeExisting
    soundSuppressedUntil = shouldIncludeExisting ? Date().addingTimeInterval(3) : .distantPast
    listenerState = .starting
    notificationHealth = nil
    lastNotificationHealthPublishedAt = .distantPast
    activityText = "正在建立通知流基线"

    monitorTask?.cancel()
    monitorTask = Task { [weak self] in
      let monitor = WeChatNotificationMonitor(
        groups: monitoredGroups,
        includeExisting: shouldIncludeExisting,
        onEvent: { event in
          Task { @MainActor [weak self] in
            self?.receive(event)
          }
        },
        onLog: { message in
          Task { @MainActor [weak self] in
            guard let self else { return }
            self.activityText = message
          }
        },
        onHealth: { health in
          Task { @MainActor [weak self] in
            guard let self else { return }
            let previousError = self.notificationHealth?.lastError
            if self.shouldPublishNotificationHealth(health) {
              self.notificationHealth = health
              self.lastNotificationHealthPublishedAt = Date()
              if self.notificationLatestRowID != health.lastRowID {
                self.notificationLatestRowID = health.lastRowID
              }
            }
            if let error = health.lastError {
              let nextState = ListenerState.recovering(error)
              if self.listenerState != nextState { self.listenerState = nextState }
              if previousError != error {
                self.playListenerIssue(subjectID: "notification-monitor:\(error)")
              }
            } else if self.listenerState != .listening {
              self.listenerState = .listening
            }
          }
        }
      )

      do {
        try await monitor.run()
        guard !Task.isCancelled else { return }
        self?.listenerState = .idle
        self?.activityText = "通知流已结束"
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        self?.listenerState = .failed(error.localizedDescription)
        self?.activityText = error.localizedDescription
        self?.refreshStatus()
        self?.playListenerIssue(subjectID: "notification-monitor-failed")
      }
    }
  }

  func stopListening() {
    monitorTask?.cancel()
    monitorTask = nil
    listenerState = .idle
    notificationHealth = nil
    lastNotificationHealthPublishedAt = .distantPast
    activityText = "监听已停止"
  }

  private func shouldPublishNotificationHealth(_ health: NotificationMonitorHealth) -> Bool {
    guard let current = notificationHealth else { return true }
    let elapsed = Date().timeIntervalSince(lastNotificationHealthPublishedAt)
    let criticalChanged = current.lastError != health.lastError
      || current.recoveryCount != health.recoveryCount
      || current.databaseResetCount != health.databaseResetCount
    if criticalChanged { return true }

    let signalChanged = current.lastDatabaseActivityAt != health.lastDatabaseActivityAt
      || current.latestActivity != health.latestActivity
      || current.lastRowID != health.lastRowID
      || current.scannedRecordCount != health.scannedRecordCount
      || current.identifiedWeChatNotificationCount != health.identifiedWeChatNotificationCount
      || current.decodedNotificationCount != health.decodedNotificationCount
      || current.groupMatchedNotificationCount != health.groupMatchedNotificationCount
      || current.unmatchedGroupNotificationCount != health.unmatchedGroupNotificationCount
      || current.matchedEventCount != health.matchedEventCount
      || current.updatedNotificationRecoveryCount != health.updatedNotificationRecoveryCount
    return signalChanged ? elapsed >= 0.5 : elapsed >= 2
  }

  func refreshStatus() {
    doctorReport = WeChatAccessibilityReader().doctor()
    let reader = NotificationDatabaseReader()
    notificationLatestRowID = try? reader.latestRowID()
    refreshHistoryDiagnostic(reader: reader)
  }

  func openFullDiskAccessSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }

  private func receive(_ event: MessageEvent) {
    let suppressSoundForReplay = Date() < soundSuppressedUntil
    guard let messageStore else {
      let consumption = MessageEventConsumer.withoutStore(event, displayedMessages: messages)
      applyMessageDisplayUpdate(consumption.displayUpdate)
      guard consumption.shouldRunNewMessageSideEffects else {
        if consumption.representsMessageUpdate {
          activityText = "刚刚更新 \(event.group) 的消息"
        }
        return
      }
      activityText = "刚刚收到 \(event.group) 的新消息"
      var soundEvents = [messageSoundEvent(kind: .newMessage, event: event, subjectID: event.group)]
      if matchesCaptureKeywords(event) {
        soundEvents.append(
          messageSoundEvent(kind: .capturedSignal, event: event, subjectID: "capture-keywords")
        )
      }
      if !suppressSoundForReplay { playNotificationSounds(soundEvents) }
      return
    }

    Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await messageStore.insert(event)
        let consumption = MessageEventConsumer.persisted(result)
        guard consumption.shouldRunNewMessageSideEffects else {
          self.applyMessageDisplayUpdate(consumption.displayUpdate)
          if consumption.representsMessageUpdate {
            self.activityText = "刚刚更新 \(event.group) 的消息"
          }
          return
        }
        self.activityText = "刚刚收到 \(event.group) 的新消息"
        var soundEvents = [
          self.messageSoundEvent(kind: .newMessage, event: event, subjectID: event.group)
        ]
        soundEvents.append(contentsOf: await self.recordCryptoAddressMentions(for: event))
        if self.automationEnabled,
          let automationBroadcaster = self.automationBroadcaster
        {
          _ = await automationBroadcaster.publish(event)
          self.automationStatus = await automationBroadcaster.status()
        }
        let rules = self.messageRules
        if !rules.isEmpty {
          let evaluation = await Task.detached(priority: .utility) {
            MessageRuleEngine.evaluate(event, rules: rules)
          }.value
          do {
            soundEvents.append(
              contentsOf: try await self.applyRuleEvaluation(
                evaluation,
                event: event,
                store: messageStore
              )
            )
          } catch {
            self.workspaceStoreError = "规则动作执行失败：\(error.localizedDescription)"
          }
        }
        if self.matchesCaptureKeywords(event),
          !soundEvents.contains(where: { $0.kind == .capturedSignal })
        {
          soundEvents.append(
            self.messageSoundEvent(
              kind: .capturedSignal,
              event: event,
              subjectID: "capture-keywords"
            )
          )
        }
        if !suppressSoundForReplay { self.playNotificationSounds(soundEvents) }
        self.applyMessageDisplayUpdate(consumption.displayUpdate)
      } catch {
        self.messageStoreError = error.localizedDescription
      }
    }
  }

  private func applyMessageDisplayUpdate(_ update: MessageEventDisplayUpdate) {
    switch update {
    case .unchanged:
      return
    case .reloadFromStore:
      scheduleMessageReload()
    case let .replaceInMemory(updatedMessages):
      messages = updatedMessages
      invalidatePresentationCaches()
    }
  }

  private func persistGroups() {
    UserDefaults.standard.set(groups, forKey: defaultsKey)
  }

  private func refreshHistoryDiagnostic(
    reader: NotificationDatabaseReader = NotificationDatabaseReader()
  ) {
    guard reader.isReadable else {
      historyDiagnostic = nil
      return
    }
    do {
      let records = try reader.recentRecords(limit: 100)
      let mapper = NotificationMapper()
      historyDiagnostic = HistoryDiagnostic(
        decodedNotificationCount: records.count,
        matchedGroupCount: records.reduce(into: 0) { count, record in
          if mapper.event(from: record, groups: groups) != nil { count += 1 }
        },
        attachmentCount: records.reduce(0) { $0 + $1.attachments.count }
      )
    } catch {
      historyDiagnostic = nil
    }
  }

  private func ensureSystemTags(in store: MessageStore) async throws {
    if captureTagID == nil {
      captureTagID = try await store.upsertTag(
        name: "系统：重点捕捉",
        colorHex: "#D97706"
      ).id
    }
    if suppressedTagID == nil {
      suppressedTagID = try await store.upsertTag(
        name: "系统：已抑制",
        colorHex: "#6B7280"
      ).id
    }
  }

  private func updateSystemTagMembership(
    from storedMessages: [StoredMessage],
    replacing: Bool
  ) {
    if replacing {
      capturedEventIDs.removeAll()
      suppressedEventIDs.removeAll()
    }
    for stored in storedMessages {
      if let captureTagID, stored.tagIDs.contains(captureTagID) {
        capturedEventIDs.insert(stored.event.eventID)
      }
      if let suppressedTagID, stored.tagIDs.contains(suppressedTagID) {
        suppressedEventIDs.insert(stored.event.eventID)
      }
    }
  }

  private func applyRuleEvaluation(
    _ evaluation: MessageRuleEvaluation,
    event: MessageEvent,
    store: MessageStore
  ) async throws -> [NotificationSoundEvent] {
    if evaluation.shouldCapture || evaluation.shouldSuppress {
      try await ensureSystemTags(in: store)
    }
    var tagIDs: [String] = []
    if evaluation.shouldCapture, let captureTagID {
      tagIDs.append(captureTagID)
      capturedEventIDs.insert(event.eventID)
    }
    if evaluation.shouldSuppress, let suppressedTagID {
      tagIDs.append(suppressedTagID)
      suppressedEventIDs.insert(event.eventID)
      capturedEventIDs.remove(event.eventID)
    }
    for tagName in evaluation.tags {
      let tag = try await store.upsertTag(name: tagName)
      tagIDs.append(tag.id)
    }
    for tagID in Set(tagIDs) {
      _ = try await store.setTag(tagID, onEventIDs: [event.eventID])
    }

    var actionErrors: [String] = []
    var enqueuedAnalysis = false
    var recordedAlert = false
    var soundEvents: [NotificationSoundEvent] = []
    if evaluation.shouldCapture {
      soundEvents.append(
        messageSoundEvent(
          kind: .capturedSignal,
          event: event,
          subjectID: evaluation.matchedRuleIDs.sorted().joined(separator: ",")
        )
      )
    }
    for intent in evaluation.actionIntents {
      switch intent.action {
      case .addTag, .capture, .suppress:
        continue
      case let .localAlert(severity, configuredTitle):
        guard let workspaceStore else {
          actionErrors.append("规则“\(intent.ruleName)”的本地提醒未执行：工作区数据库不可用")
          continue
        }
        let trimmedTitle = configuredTitle?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let alertTitle = trimmedTitle?.isEmpty == false ? trimmedTitle! : intent.ruleName
        do {
          let recorded = try await workspaceStore.recordAlert(
            severity: severity,
            title: alertTitle,
            sourceEventIDs: [event.eventID],
            deduplicationKey: "rule-alert:v1:\(intent.ruleID):\(intent.ruleRevision):\(intent.actionIndex)",
            cooldownInterval: 5 * 60,
            ruleID: intent.ruleID
          )
          alertSourceMessages[event.eventID] = event
          workspaceAlerts.removeAll { $0.alertID == recorded.alert.alertID }
          workspaceAlerts.append(recorded.alert)
          workspaceAlerts = sortedAlerts(workspaceAlerts)
          recordedAlert = true
          if recorded.disposition == .created {
            soundEvents.append(
              messageSoundEvent(
                kind: soundEventKind(for: severity),
                event: event,
                subjectID: intent.ruleID
              )
            )
          }
        } catch {
          actionErrors.append("规则“\(intent.ruleName)”的本地提醒未执行：\(error.localizedDescription)")
        }
      case let .enqueueSummary(configurationID):
        guard let workspaceStore else {
          actionErrors.append("规则“\(intent.ruleName)”的摘要未排队：工作区数据库不可用")
          continue
        }
        let providerID: String?
        if let configurationID {
          providerID = configurationID
        } else if let defaultProviderID {
          providerID = defaultProviderID
        } else {
          providerID = (try? await workspaceStore.defaultProviderConfiguration())?.configurationID
        }
        guard let providerID else {
          actionErrors.append("规则“\(intent.ruleName)”的摘要未排队：尚未配置 AI 服务")
          continue
        }
        do {
          let frozen = try await store.freeze(
            eventIDs: [event.eventID],
            scope: MessageScope(groups: [event.group])
          )
          _ = try await workspaceStore.enqueueAnalysisJob(
            frozenRangeID: frozen.id,
            providerID: providerID,
            mode: .digest,
            idempotencyKey: "rule-summary:v1:\(intent.intentID)"
          )
          enqueuedAnalysis = true
        } catch {
          actionErrors.append("规则“\(intent.ruleName)”的摘要未排队：\(error.localizedDescription)")
        }
      case let .invokeScript(scriptID, _):
        actionErrors.append(
          "规则“\(intent.ruleName)”请求脚本 \(scriptID)，但当前版本未执行脚本动作"
        )
      }
    }

    if enqueuedAnalysis {
      analysisJobs = try await workspaceStore?.analysisJobs(limit: 200) ?? analysisJobs
      isProcessingAnalysisQueue = analysisJobs.contains { !$0.state.isTerminal }
      refreshAnalysisStatusUntilSettled()
    }
    if recordedAlert {
      await reloadAlerts()
    }
    if !actionErrors.isEmpty {
      workspaceStoreError = actionErrors.joined(separator: "；")
    }
    return soundEvents
  }

  private func currentMessageScope(store: MessageStore) async throws -> MessageScope {
    if let focus = messageContextFocus {
      reviewCursors = [:]
      return MessageScope(groups: [focus.group])
    }
    let selectedGroups: Set<String>
    switch workspaceSelection {
    case .group(let group):
      selectedGroups = [group]
    case .inbox, .captured:
      selectedGroups = Set(groups)
    case .analyses, .alerts, .meme, .market, .rules, .trading, .automations, .sounds, .providers,
      .diagnostics:
      selectedGroups = []
    }

    var startDate: Date?
    var endDate: Date?
    switch timePreset {
    case .all:
      reviewCursors = [:]
    case .custom:
      let range = MessageDateRange(start: customRangeStart, end: customRangeEnd).normalized
      startDate = range.start
      endDate = range.end
      reviewCursors = [:]
    case .last30Minutes, .last2Hours, .today:
      if let range = timePreset.fixedRange() {
        startDate = range.start
        endDate = range.end
      }
      reviewCursors = [:]
    case .sinceLastReview:
      let cursorGroups: [String]
      if case .group(let group) = workspaceSelection {
        cursorGroups = [group]
      } else {
        cursorGroups = groups
      }
      var cursors: [String: ReviewCursor] = [:]
      for group in cursorGroups {
        if let cursor = try await store.reviewCursor(forGroup: group) {
          cursors[group] = cursor
        }
      }
      reviewCursors = cursors
    }

    let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let messageTypes: Set<MessageKind>
    switch kindFilter {
    case .all: messageTypes = []
    case .text: messageTypes = [.text]
    case .media: messageTypes = [.media]
    }
    let includeTerms = Set(parsedTerms(includeKeywords))
    let excludeTerms = Set(parsedTerms(excludeKeywords))
    let mentionTerms: Set<String> = onlyMentions
      ? ["@了你", "提到了你", "mentioned you"]
      : []
    let excludedTags = suppressedTagID.map { Set([$0]) } ?? []
    let anyMatch: MessageScopeAnyMatch?
    if workspaceSelection == .captured {
      anyMatch = MessageScopeAnyMatch(
        tagIDs: captureTagID.map { Set([$0]) } ?? [],
        terms: Set(parsedTerms(captureKeywords))
      )
    } else {
      anyMatch = nil
    }
    return MessageScope(
      groups: selectedGroups,
      startDate: startDate,
      endDate: endDate,
      messageTypes: messageTypes,
      searchText: trimmedSearch.isEmpty ? nil : trimmedSearch,
      excludedTagIDs: excludedTags,
      includeAnyTerms: includeTerms,
      excludeAnyTerms: excludeTerms,
      contentContainsAnyTerms: mentionTerms,
      requiresKnownSender: onlyKnownSenders,
      afterReviewCursors: Array(reviewCursors.values),
      anyMatch: anyMatch
    )
  }

  private func globalCapturedScope() -> MessageScope {
    MessageScope(
      groups: Set(groups),
      excludedTagIDs: suppressedTagID.map { Set([$0]) } ?? [],
      anyMatch: MessageScopeAnyMatch(
        tagIDs: captureTagID.map { Set([$0]) } ?? [],
        terms: Set(parsedTerms(captureKeywords))
      )
    )
  }

  private func previousFlowAnalytics(
    for scope: MessageScope,
    store: MessageStore
  ) async throws -> MessageFlowAnalytics? {
    guard scope.afterReviewCursors.isEmpty,
      let start = scope.startDate,
      let end = scope.endDate,
      end > start
    else {
      return nil
    }

    let duration = end.timeIntervalSince(start)
    var previousScope = scope
    previousScope.startDate = start.addingTimeInterval(-duration)
    previousScope.endDate = start
    return try await store.flowAnalytics(in: previousScope)
  }

  private func managementMetricInputs(
    for scope: MessageScope,
    store: MessageStore
  ) async throws -> (
    baseScope: MessageScope,
    priorityMatch: MessageScopeAnyMatch?,
    suppressedTagIDs: Set<String>,
    reviewCursors: [ReviewCursor]
  ) {
    let suppressedTags = suppressedTagID.map { Set([$0]) } ?? []
    var baseScope = scope
    baseScope.afterReviewCursors = []
    baseScope.anyMatch = nil
    baseScope.excludedTagIDs.subtract(suppressedTags)

    let priority = MessageScopeAnyMatch(
      tagIDs: captureTagID.map { Set([$0]) } ?? [],
      terms: Set(parsedTerms(captureKeywords))
    )
    let priorityMatch = priority.tagIDs.isEmpty && priority.terms.isEmpty ? nil : priority

    var cursors: [ReviewCursor] = []
    for group in baseScope.groups.sorted() {
      if let cursor = try await store.reviewCursor(forGroup: group) {
        cursors.append(cursor)
      }
    }
    return (baseScope, priorityMatch, suppressedTags, cursors)
  }

  private func matchesReviewCutoff(_ event: MessageEvent) -> Bool {
    guard timePreset == .sinceLastReview, let cursor = reviewCursors[event.group] else {
      return true
    }
    if event.observedAt != cursor.observedAt {
      return event.observedAt > cursor.observedAt
    }
    switch (event.sourceSequence, cursor.sourceSequence) {
    case let (eventSequence?, cursorSequence?) where eventSequence != cursorSequence:
      return eventSequence > cursorSequence
    case (_?, nil):
      return false
    case (nil, _?):
      return true
    default:
      return event.eventID > cursor.eventID
    }
  }

  private func matchesConfiguredFilters(_ event: MessageEvent) -> Bool {
    let values = searchableValues(event)
    let included = parsedTerms(includeKeywords)
    if !included.isEmpty,
      !included.contains(where: { term in
        values.contains { $0.localizedCaseInsensitiveContains(term) }
      })
    {
      return false
    }

    let excluded = parsedTerms(excludeKeywords)
    if excluded.contains(where: { term in
      values.contains { $0.localizedCaseInsensitiveContains(term) }
    }) {
      return false
    }
    if onlyKnownSenders {
      let hasStableID = event.senderStableID?
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      let hasDisplayName = event.senderDisplayName?
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      if !hasStableID, !hasDisplayName { return false }
    }
    if onlyMentions {
      let mentionMarkers = ["@了你", "提到了你", "mentioned you"]
      guard mentionMarkers.contains(where: event.content.localizedCaseInsensitiveContains) else {
        return false
      }
    }
    switch kindFilter {
    case .all: break
    case .text where event.messageType != .text: return false
    case .media where event.messageType != .media: return false
    default: break
    }
    return true
  }

  private func matchesAddressFilters(_ event: MessageEvent) -> Bool {
    let matches = addressMatches(for: event)
    if let focusedAddress,
      !matches.contains(where: {
        $0.family == focusedAddress.family
          && $0.network == focusedAddress.network
          && $0.normalizedAddress == focusedAddress.normalizedAddress
      })
    {
      return false
    }

    switch addressFilter {
    case .all:
      return true
    case .any:
      return !matches.isEmpty
    case .unresolved:
      return matches.contains { match in
        match.family == .evm && match.network == .evm
      }
    case .ethereum:
      return matches.contains { $0.network == .ethereum }
    case .base:
      return matches.contains { $0.network == .base }
    case .bsc:
      return matches.contains { $0.network == .bsc }
    case .robinhood:
      return matches.contains { $0.network == .robinhood }
    case .solana:
      return matches.contains { $0.network == .solana }
    case .webLink:
      return !webLinks(for: event).isEmpty
    }
  }

  private func searchableValues(_ event: MessageEvent) -> [String] {
    [event.senderDisplayName ?? "", event.content, event.group]
  }

  private func reloadAlerts() async {
    guard let workspaceStore else {
      workspaceStoreError = workspaceStoreError ?? "工作区数据库不可用"
      return
    }
    do {
      async let alerts = workspaceStore.alerts(includeAcknowledged: true, limit: 200)
      async let unacknowledgedAlerts = workspaceStore.alerts(
        includeAcknowledged: false,
        limit: 500
      )
      async let addressIncidents = workspaceStore.crossGroupAddressIncidents(limit: 500)
      let loadedAlerts = try await alerts
      let loadedUnacknowledgedAlerts = try await unacknowledgedAlerts
      crossGroupAddressIncidents = try await addressIncidents
      workspaceAlerts = combinedAlerts(
        recent: loadedAlerts,
        unacknowledged: loadedUnacknowledgedAlerts
      )
      unacknowledgedAlertCount = loadedUnacknowledgedAlerts.count
      unacknowledgedAlertCountIsCapped = loadedUnacknowledgedAlerts.count == 500
      try await cacheLoadedAlertSources()
    } catch {
      workspaceStoreError = "无法刷新提醒：\(error.localizedDescription)"
    }
  }

  private func cacheLoadedAlertSources() async throws {
    var orderedSourceIDs: [String] = []
    var seen = Set<String>()
    for alert in workspaceAlerts {
      let sampledIDs = Array(alert.sourceEventIDs.prefix(50))
        + Array(alert.sourceEventIDs.suffix(50))
      for eventID in sampledIDs where seen.insert(eventID).inserted {
        guard orderedSourceIDs.count < 2_000 else { break }
        orderedSourceIDs.append(eventID)
      }
      if orderedSourceIDs.count >= 2_000 { break }
    }
    let sourceIDs = Set(orderedSourceIDs)
    for event in messages where sourceIDs.contains(event.eventID) {
      alertSourceMessages[event.eventID] = event
    }
    if let messageStore {
      let missing = orderedSourceIDs.filter { alertSourceMessages[$0] == nil }
      let stored = try await messageStore.messages(eventIDs: missing)
      for message in stored {
        alertSourceMessages[message.event.eventID] = message.event
      }
    }
    if let workspaceStore {
      for start in stride(from: 0, to: orderedSourceIDs.count, by: 500) {
        let end = min(start + 500, orderedSourceIDs.count)
        let enrichments = try await workspaceStore.caSignalEnrichments(
          eventIDs: Array(orderedSourceIDs[start..<end])
        )
        mergeCASignalEnrichments(enrichments)
      }
    }
    alertSourceMessages = alertSourceMessages.filter { sourceIDs.contains($0.key) }
  }

  private func scheduleAddressBackfill() {
    addressBackfillTask?.cancel()
    addressBackfillTask = Task { [weak self] in
      await self?.backfillRecentCryptoAddressMentions()
    }
  }

  private func backfillRecentCryptoAddressMentions() async {
    guard let messageStore, let workspaceStore, !groups.isEmpty else { return }
    let shouldSeedCAWatchPool = caWatchPoolItems.isEmpty
    var latestCASignals: [String: (match: CryptoAddressMatch, event: MessageEvent)] = [:]
    let end = Date().addingTimeInterval(0.001)
    let scope = MessageScope(
      groups: Set(groups),
      startDate: end.addingTimeInterval(-WorkspaceStore.crossGroupAddressWindow),
      endDate: end
    )
    var cursor: MessagePageCursor?
    var changedAlerts = false
    do {
      repeat {
        try Task.checkCancellation()
        let page = try await messageStore.messages(
          matching: MessageQuery(
            scope: scope,
            limit: 500,
            after: cursor,
            order: .oldestFirst
          )
        )
        let detected = await Task.detached(priority: .utility) {
          page.messages.map { stored in
            (stored.event, CryptoAddressDetector.matches(in: stored.event.content))
          }
        }.value
        for (event, matches) in detected {
          try Task.checkCancellation()
          for match in matches {
            let result = try await workspaceStore.recordCryptoAddressMention(match, event: event)
            if result.incident != nil { changedAlerts = true }
            if shouldSeedCAWatchPool {
              let key = caPoolItemKey(
                family: match.family,
                network: match.network,
                address: match.normalizedAddress
              )
              latestCASignals[key] = (match, event)
            }
          }
        }
        cursor = page.nextCursor
        if !page.hasMore { break }
      } while cursor != nil
      if changedAlerts { await reloadAlerts() }
      if !memeAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        scheduleMemeMentionSummaryRefresh()
      }
      if shouldSeedCAWatchPool {
        let seeds = latestCASignals.values
          .sorted { $0.event.observedAt > $1.event.observedAt }
          .prefix(caWatchPoolConfiguration.capacity)
        for seed in seeds {
          await recordCASignals([seed.match], event: seed.event)
        }
      }
    } catch is CancellationError {
      return
    } catch {
      workspaceStoreError = "最近 24 小时地址回填失败：\(error.localizedDescription)"
    }
  }

  private func recordCryptoAddressMentions(
    for event: MessageEvent
  ) async -> [NotificationSoundEvent] {
    let matches = await Task.detached(priority: .utility) {
      CryptoAddressDetector.matches(in: event.content)
    }.value
    guard !matches.isEmpty else { return [] }
    await recordCASignals(matches, event: event)
    let triggerSnapshots = await resolveCASnapshotsForNotification(
      matches,
      eventID: event.eventID
    )
    var soundEvents: [NotificationSoundEvent] = []
    var seenAddresses = Set<String>()
    for match in matches where seenAddresses.insert(match.id).inserted {
      soundEvents.append(
        messageSoundEvent(
          kind: .cryptoAddress,
          event: event,
          subjectID: match.id
        )
      )
    }
    guard let workspaceStore else { return soundEvents }
    do {
      var changedAlerts = false
      for match in matches {
        let result = try await workspaceStore.recordCryptoAddressMention(
          match,
          event: event,
          triggerSnapshot: triggerSnapshots[match.id]
        )
        if let incident = result.incident {
          changedAlerts = true
          let threshold = incident.groupCount >= 3 ? "3-plus" : "2"
          soundEvents.append(
            messageSoundEvent(
              kind: .crossGroupAddress,
              event: event,
              subjectID: "\(match.id):\(threshold)"
            )
          )
        }
      }
      if changedAlerts {
        alertSourceMessages[event.eventID] = event
        await reloadAlerts()
      }
      let currentMemeAddress = memeAddressDraft
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if matches.contains(where: { $0.normalizedAddress == currentMemeAddress }) {
        scheduleMemeMentionSummaryRefresh()
      }
      scheduleTradeAutomationEvaluation(matches: matches, event: event)
    } catch {
      workspaceStoreError = "跨群地址聚合失败：\(error.localizedDescription)"
    }
    return soundEvents
  }

  private func resolveCASnapshotsForNotification(
    _ matches: [CryptoAddressMatch],
    eventID: String
  ) async -> [String: CATokenMarketSnapshot] {
    var snapshots: [String: CATokenMarketSnapshot] = [:]
    var seen = Set<String>()
    for match in matches where seen.insert(match.id).inserted {
      if let snapshot = caSignalEnrichment(eventID: eventID, match: match)?.snapshot {
        snapshots[match.id] = snapshot
        continue
      }
      let taskKey = caPoolItemKey(
        family: match.family,
        network: match.network,
        address: match.normalizedAddress
      )
      if let task = standaloneCAEnrichmentTasks[taskKey] {
        await task.value
      } else {
        await resolveStandaloneCAEnrichment(match)
      }
      if let snapshot = caSignalEnrichment(eventID: eventID, match: match)?.snapshot {
        snapshots[match.id] = snapshot
      }
    }
    return snapshots
  }

  private func sortedAlerts(_ alerts: [WorkspaceAlert]) -> [WorkspaceAlert] {
    alerts.sorted { lhs, rhs in
      if lhs.isAcknowledged != rhs.isAcknowledged {
        return !lhs.isAcknowledged
      }
      if lhs.updatedAt != rhs.updatedAt {
        return lhs.updatedAt > rhs.updatedAt
      }
      return lhs.alertID > rhs.alertID
    }
  }

  private func combinedAlerts(
    recent: [WorkspaceAlert],
    unacknowledged: [WorkspaceAlert]
  ) -> [WorkspaceAlert] {
    var alertsByID = Dictionary(uniqueKeysWithValues: recent.map { ($0.alertID, $0) })
    for alert in unacknowledged {
      alertsByID[alert.alertID] = alert
    }
    return sortedAlerts(Array(alertsByID.values))
  }

  private func messageSoundEvent(
    kind: NotificationSoundEventKind,
    event: MessageEvent,
    subjectID: String
  ) -> NotificationSoundEvent {
    NotificationSoundEvent(
      kind: kind,
      eventID: event.eventID,
      group: event.group,
      senderStableID: event.senderStableID,
      senderDisplayName: event.senderDisplayName,
      subjectID: subjectID.isEmpty ? event.eventID : subjectID
    )
  }

  private func soundEventKind(
    for severity: MessageRuleAlertSeverity
  ) -> NotificationSoundEventKind {
    switch severity {
    case .information: return .alertInformation
    case .warning: return .alertWarning
    case .critical: return .alertCritical
    }
  }

  private func matchesCaptureKeywords(_ event: MessageEvent) -> Bool {
    let terms = parsedTerms(captureKeywords)
    return terms.contains { term in
      searchableValues(event).contains { $0.localizedCaseInsensitiveContains(term) }
    }
  }

  private func playListenerIssue(subjectID: String) {
    playNotificationSounds([
      NotificationSoundEvent(
        kind: .listenerIssue,
        eventID: subjectID,
        subjectID: subjectID
      )
    ])
  }

  private func playNotificationSounds(_ events: [NotificationSoundEvent]) {
    guard !events.isEmpty, Date() >= soundSuppressedUntil else { return }
    let enrichedEvents = events.map(soundEventWithSpeechDetail)
    if let resolution = soundController.playBest(
      events: enrichedEvents,
      configuration: soundConfiguration,
      appIsActive: NSApp.isActive,
      speechAPIKey: try? credentialStore.speechAPIKey(),
      speechStatus: { [weak self] status in
        self?.soundStatusText = status
      }
    ) {
      soundStatusText = resolution.rule.effectiveOutputMode.includesSpeech
        ? "正在准备：\(resolution.rule.name)"
        : "已播放：\(resolution.rule.name)"
    }
  }

  private func soundEventWithSpeechDetail(
    _ event: NotificationSoundEvent
  ) -> NotificationSoundEvent {
    guard event.kind == .cryptoAddress || event.kind == .crossGroupAddress,
      let address = soundEventAddress(event)
    else {
      return event
    }

    let directSnapshot = caSignalEnrichments.values
      .filter {
        $0.eventID == event.eventID
          && $0.normalizedAddress == address
          && $0.snapshot != nil
      }
      .sorted { $0.updatedAt > $1.updatedAt }
      .compactMap(\.snapshot)
      .first
    let incident = event.kind == .crossGroupAddress
      ? crossGroupAddressIncidents.first(where: { $0.normalizedAddress == address })
      : nil
    let snapshot = directSnapshot ?? incident.flatMap { caTriggerSnapshot(for: $0) }

    let sender = spokenSenderName(event)
    var details: [String] = []
    if let snapshot {
      if let incident {
        details.append("\(sender) 发送的代币 \(speechTokenTitle(snapshot)) 已在 \(incident.groupCount) 个群出现")
      } else {
        details.append("\(sender) 发送了代币 \(speechTokenTitle(snapshot))")
      }
      details.append("网络 \(snapshot.chain.localizedTitle)")
      if let marketCap = snapshot.marketCapUSD, marketCap.isFinite, marketCap >= 0 {
      details.append("提示市值约 \(spokenMarketCap(marketCap))")
      } else {
      details.append("提示市值未返回")
      }
    } else {
      details.append("\(sender) 发送了一个待识别代币")
      details.append("提示市值待识别")
    }

    return NotificationSoundEvent(
      kind: event.kind,
      eventID: event.eventID,
      group: event.group,
      senderStableID: event.senderStableID,
      senderDisplayName: event.senderDisplayName,
      subjectID: event.subjectID,
      speechDetail: details.joined(separator: "，")
    )
  }

  private func spokenSenderName(_ event: NotificationSoundEvent) -> String {
    let value = event.senderDisplayName?
      .components(separatedBy: .newlines)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? "群内成员" : String(value.prefix(40))
  }

  private func soundEventAddress(_ event: NotificationSoundEvent) -> String? {
    let rawValue = event.subjectID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawValue.isEmpty else { return nil }
    if event.kind == .crossGroupAddress {
      return rawValue.split(separator: ":", maxSplits: 1).first.map(String.init)
    }
    return rawValue
  }

  private func speechTokenTitle(_ snapshot: CATokenMarketSnapshot) -> String {
    if !snapshot.symbol.isEmpty, !snapshot.name.isEmpty,
      snapshot.symbol.caseInsensitiveCompare(snapshot.name) != .orderedSame
    {
      return "\(snapshot.symbol)，\(snapshot.name)"
    }
    if !snapshot.symbol.isEmpty { return snapshot.symbol }
    if !snapshot.name.isEmpty { return snapshot.name }
    return "未知代币"
  }

  private func spokenMarketCap(_ value: Double) -> String {
    let magnitude = abs(value)
    if magnitude >= 100_000_000 {
      return (value / 100_000_000).formatted(
        .number.precision(.fractionLength(0...1))
      ) + " 亿美元"
    }
    if magnitude >= 10_000 {
      return (value / 10_000).formatted(
        .number.precision(.fractionLength(0...1))
      ) + " 万美元"
    }
    return value.formatted(.number.precision(.fractionLength(0...2))) + " 美元"
  }

  private func parsedTerms(_ value: String) -> [String] {
    value
      .components(separatedBy: CharacterSet(charactersIn: ",，\n"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}
