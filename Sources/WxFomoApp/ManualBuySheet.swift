import AppKit
import SwiftUI
import WxFomoCore

struct ManualBuySheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss

  let context: ManualBuyContext

  @State private var mode: ManualBuyMode
  @State private var selectedChain: GMGNChain?
  @State private var amountText = "0.01"
  @State private var slippagePercent = 12
  @State private var antiMEV = true
  @State private var quotePreview: GMGNTradeQuote?
  @State private var preparation: ManualBuyPreparation?
  @State private var receipt: GMGNTradeOrderSnapshot?
  @State private var isPreparing = false
  @State private var activePreparationID: UUID?
  @State private var isSubmitting = false
  @State private var errorMessage: String?
  @State private var showsConfirmation = false

  init(context: ManualBuyContext) {
    self.context = context
    _mode = State(initialValue: context.mode)
    let initialChain = Self.supportedChains.contains {
      $0 == context.suggestedChain
    } ? context.suggestedChain : nil
    _selectedChain = State(initialValue: initialChain)
    if let suggestedAmountNative = context.suggestedAmountNative {
      _amountText = State(
        initialValue: suggestedAmountNative.formatted(
          .number.precision(.fractionLength(0...8))
        )
      )
    } else if initialChain != nil,
      let savedAmount = Self.savedQuickAmount()
    {
      _amountText = State(initialValue: savedAmount)
    }
    if let suggestedSlippagePercent = context.suggestedSlippagePercent,
      Self.slippageOptions.contains(suggestedSlippagePercent)
    {
      _slippagePercent = State(initialValue: suggestedSlippagePercent)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          tokenSummary
          if mode == .standard || selectedChain == nil || hasMultipleChainCandidates {
            chainDetectionSection
          }
          if mode == .quick { quickForm } else { standardForm }
          if let configurationNoticeMessage {
            configurationNotice(configurationNoticeMessage)
          }
          preparationSummary
          if let errorMessage { errorView(errorMessage) }
          if let receipt { receiptView(receipt) }
        }
        .padding(20)
      }
      Divider()
      footer
    }
    .frame(width: 540, height: 520)
    .task {
      model.refreshGMGNTradeConfiguration()
      model.refreshGMGNPortfolio()
    }
    .task(id: preparationKey) {
      guard mode == .quick, canPrepare, receipt == nil else { return }
      await prepareTrade(debounced: true)
    }
    .onChange(of: amountText) {
      invalidatePreparation()
      if mode == .quick { persistQuickAmount() }
    }
    .confirmationDialog(
      preparation?.safety.requiresAdditionalConfirmation == true
        ? "高风险代币，仍要买入？" : "确认提交真实买入？",
      isPresented: $showsConfirmation,
      titleVisibility: .visible
    ) {
      Button(standardConfirmationTitle, role: .destructive) {
        submitBuy(
          authorization: .standardConfirmation,
          confirmedHighRisk: preparation?.safety.requiresAdditionalConfirmation == true
        )
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text(confirmationSummary)
    }
  }

  private var header: some View {
    HStack(spacing: 11) {
      Image(systemName: mode == .quick ? "bolt.fill" : "arrow.left.arrow.right.circle.fill")
        .font(.system(size: 21, weight: .semibold))
        .foregroundStyle(mode == .quick ? Color.orange : WxFomoTheme.signal)
        .frame(width: 26)
      VStack(alignment: .leading, spacing: 2) {
        Text(mode == .quick ? "快速买入" : "普通买入")
          .font(.headline)
        Text(context.sourceTitle ?? "当前 CA")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      Picker("模式", selection: $mode) {
        ForEach(ManualBuyMode.allCases) { option in
          Text(option.title).tag(option)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 150)
      .onChange(of: mode) { invalidatePreparation() }
      Button { dismiss() } label: { Image(systemName: "xmark") }
        .buttonStyle(.borderless)
        .help("关闭")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
  }

  private var tokenSummary: some View {
    HStack(spacing: 12) {
      tokenLogo
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Text(tokenTitle)
            .font(.title3.weight(.semibold))
            .lineLimit(1)
          if let chain = selectedChain {
            Text(chain.localizedTitle)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
          }
        }
        Text(context.address)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
        HStack(spacing: 10) {
          if let marketCapUSD { Text("市值 \(formattedUSD(marketCapUSD))") }
          if let liquidityUSD { Text("池子 \(formattedUSD(liquidityUSD))") }
          if let mentions = context.mentionSummary { Text(mentions) }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
  }

  @ViewBuilder
  private var chainDetectionSection: some View {
    let candidates = context.chainCandidates.filter { Self.supportedChains.contains($0.chain) }
    if context.chainDetectionMessage != nil || !candidates.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        if let message = context.chainDetectionMessage {
          Label(message, systemImage: selectedChain == nil ? "questionmark.circle" : "checkmark.circle")
            .font(.caption)
            .foregroundStyle(selectedChain == nil ? Color.orange : Color.secondary)
        }
        if !candidates.isEmpty {
          HStack(spacing: 8) {
            ForEach(candidates) { candidate in
              Button {
                selectedChain = candidate.chain
                invalidatePreparation()
              } label: {
                HStack(spacing: 5) {
                  if selectedChain == candidate.chain {
                    Image(systemName: "checkmark")
                  }
                  Text(candidate.chain.localizedTitle)
                  if let liquidity = candidate.maxLiquidityUSD {
                    Text(formattedUSD(liquidity))
                      .foregroundStyle(.secondary)
                  }
                }
              }
              .buttonStyle(.bordered)
              .tint(selectedChain == candidate.chain ? WxFomoTheme.signal : .secondary)
            }
          }
        }
      }
      .padding(.horizontal, 2)
    }
  }

  private var quickForm: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(alignment: .center, spacing: 10) {
        TextField("0.01", text: $amountText)
          .textFieldStyle(.plain)
          .font(.title2.monospacedDigit().weight(.semibold))
          .frame(minWidth: 90, maxWidth: 150)
        Text(nativeSymbol)
          .font(.callout.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        Label("买入金额", systemImage: "bolt.fill")
          .font(.caption.weight(.medium))
          .foregroundStyle(.orange)
      }
      .padding(.horizontal, 12)
      .frame(height: 48)
      .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .stroke(parsedAmount == nil ? Color.red : Color(nsColor: .separatorColor), lineWidth: 1)
      }

      HStack(spacing: 7) {
        ForEach(Self.presets, id: \.self) { amount in
          Button(formattedAmount(amount)) {
            amountText = formattedAmount(amount)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
        Spacer(minLength: 0)
      }

      Divider()

      HStack(spacing: 9) {
        compactMenu(title: selectedChain?.localizedTitle ?? "选择网络") {
          ForEach(Self.supportedChains) { chain in
            Button(chain.localizedTitle) {
              selectedChain = chain
              invalidatePreparation()
            }
          }
        }
        Text(walletSummary)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 4)
        compactMenu(title: "滑点 \(slippagePercent)%") {
          ForEach(Self.slippageOptions, id: \.self) { value in
            Button("\(value)%") {
              slippagePercent = value
              invalidatePreparation()
            }
          }
        }
        Image(
          systemName: supportsAntiMEV
            ? "shield.checkered" : "point.3.connected.trianglepath.dotted"
        )
        .foregroundStyle(.secondary)
        .help(supportsAntiMEV ? "Anti-MEV 已启用" : "使用 GMGN 标准路由")
      }
    }
    .padding(12)
    .background(
      Color(nsColor: .controlBackgroundColor).opacity(0.72),
      in: RoundedRectangle(cornerRadius: 7)
    )
  }

  private var standardForm: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack {
        Label("交易参数", systemImage: "slider.horizontal.3").font(.headline)
        Spacer()
        Text(model.gmgnTradeConfigurationState?.localizedTitle ?? "检查配置中")
          .font(.caption)
          .foregroundStyle(configurationColor)
      }
      LabeledContent("网络") {
        Picker("网络", selection: $selectedChain) {
          Text("选择网络").tag(Optional<GMGNChain>.none)
          ForEach(Self.supportedChains) { chain in
            Text(chain.localizedTitle).tag(Optional(chain))
          }
        }
        .labelsHidden()
        .frame(width: 170)
        .onChange(of: selectedChain) { invalidatePreparation() }
      }
      LabeledContent("买入金额") {
        HStack(spacing: 7) {
          TextField("0.01", text: $amountText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 110)
            .onSubmit { invalidatePreparation() }
          Text(nativeSymbol)
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
        }
      }
      HStack(spacing: 7) {
        Text("快捷").font(.caption).foregroundStyle(.secondary)
        ForEach(Self.presets, id: \.self) { preset in
          Button(formattedAmount(preset)) {
            amountText = formattedAmount(preset)
            invalidatePreparation()
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
      LabeledContent("最大滑点") {
        Picker("最大滑点", selection: $slippagePercent) {
          ForEach(Self.slippageOptions, id: \.self) { value in
            Text("\(value)%").tag(value)
          }
        }
        .labelsHidden()
        .frame(width: 120)
        .onChange(of: slippagePercent) { invalidatePreparation() }
      }
      if supportsAntiMEV {
        Toggle("Anti-MEV 保护", isOn: $antiMEV)
      } else if let selectedChain {
        Label("\(selectedChain.localizedTitle) 使用 GMGN 标准路由", systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Label(walletSummary, systemImage: "wallet.pass")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
    }
    .padding(13)
    .background(
      Color(nsColor: .controlBackgroundColor).opacity(0.68),
      in: RoundedRectangle(cornerRadius: 7)
    )
  }

  @ViewBuilder
  private var preparationSummary: some View {
    if isPreparing {
      HStack(spacing: 10) {
        ProgressView().controlSize(.small)
        if mode == .quick, let quotePreview {
          Text("预计 \(formattedQuoteOutput(quotePreview.outputAmount))")
            .font(.callout.monospacedDigit().weight(.medium))
          Text("蜜罐检查中 · Rug 已跳过")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text(mode == .quick ? "正在获取实时报价" : "正在定位池子、检查安全并获取报价")
            .font(.callout.weight(.medium))
        }
        Spacer()
      }
      .padding(13)
      .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
    } else if let preparation, mode == .quick {
      HStack(spacing: 8) {
        Image(systemName: safetySymbol(preparation.safety.level))
          .foregroundStyle(safetyColor(preparation.safety.level))
        Text(preparation.safety.title).font(.callout.weight(.semibold))
        Spacer()
        Text("预计 \(formattedQuoteOutput(preparation.quote.outputAmount))")
          .font(.caption.monospacedDigit().weight(.medium))
        Text(preparation.quote.quotedAt, style: .time)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .help(preparation.safety.detail)
      .padding(13)
      .background(
        safetyColor(preparation.safety.level).opacity(0.075),
        in: RoundedRectangle(cornerRadius: 7)
      )
    } else if let preparation {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Image(systemName: safetySymbol(preparation.safety.level))
            .foregroundStyle(safetyColor(preparation.safety.level))
          Text(preparation.safety.title).font(.callout.weight(.semibold))
          Text(preparation.safety.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Text(preparation.quote.quotedAt, style: .time)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        HStack(spacing: 24) {
          quoteMetric("支付", "\(amountText) \(nativeSymbol)")
          quoteMetric("预计获得", formattedQuoteOutput(preparation.quote.outputAmount))
          if let minimum = preparation.quote.minimumOutputAmount {
            quoteMetric("最低获得", formattedQuoteOutput(minimum))
          }
        }
        .font(.caption.monospacedDigit())
      }
      .padding(13)
      .background(
        safetyColor(preparation.safety.level).opacity(0.075),
        in: RoundedRectangle(cornerRadius: 7)
      )
    }
  }

  private var footer: some View {
    HStack(spacing: 12) {
      if mode == .standard {
        VStack(alignment: .leading, spacing: 2) {
          Text("报价与安全结果 30 秒内有效")
            .font(.caption.weight(.medium))
          Text("链上交易不可撤销")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      if receipt != nil {
        Button("完成") { dismiss() }.buttonStyle(.borderedProminent)
      } else if mode == .quick {
        quickFooterAction
      } else {
        standardFooterAction
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  @ViewBuilder
  private var quickFooterAction: some View {
    if let preparation, preparation.safety.level == .high {
      Button("切换普通模式") {
        mode = .standard
        invalidatePreparation()
      }
      .buttonStyle(.borderedProminent)
      .tint(.orange)
    } else if preparation?.safety.level == .blocked {
      Button("已拦截") {}
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(true)
    } else {
      Button {
        submitBuy(authorization: .quickBuyButton, confirmedHighRisk: false)
      } label: {
        if isPreparing || isSubmitting {
          ProgressView().controlSize(.small)
        } else {
          Label("立即买入 \(amountText) \(nativeSymbol)", systemImage: "bolt.fill")
        }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(.orange)
      .disabled(!canSubmitQuick || isPreparing || isSubmitting)
    }
  }

  @ViewBuilder
  private var standardFooterAction: some View {
    if let preparation, preparation.safety.allowsStandardBuy {
      Button("确认买入 \(amountText) \(nativeSymbol)") {
        showsConfirmation = true
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(preparation.safety.level == .high ? .orange : WxFomoTheme.signal)
      .disabled(isSubmitting || model.tradeAutomationConfiguration.emergencyStopped)
    } else {
      Button {
        Task { await prepareTrade(debounced: false) }
      } label: {
        if isPreparing {
          ProgressView().controlSize(.small)
        } else {
          Label(
            preparation == nil ? "检查并报价" : "重新检查",
            systemImage: "bolt.horizontal.circle"
          )
        }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(!canPrepare || isPreparing)
    }
  }

  private func compactMenu<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    Menu(content: content) {
      HStack(spacing: 5) {
        Text(title).lineLimit(1)
        Image(systemName: "chevron.down").font(.caption2)
      }
      .frame(minWidth: 95)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private func errorView(_ message: String) -> some View {
    Label(message, systemImage: "exclamationmark.triangle.fill")
      .font(.caption)
      .foregroundStyle(.red)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
  }

  private func configurationNotice(_ message: String) -> some View {
    Label(message, systemImage: "exclamationmark.circle.fill")
      .font(.caption)
      .foregroundStyle(.orange)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
  }

  private func receiptView(_ receipt: GMGNTradeOrderSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Label(
        receipt.isConfirmed ? "买入已确认" : "订单处理中",
        systemImage: receipt.isConfirmed
          ? "checkmark.circle.fill" : "clock.arrow.circlepath"
      )
      .font(.headline)
      .foregroundStyle(
        receipt.isConfirmed ? WxFomoTheme.signal : .orange
      )
      if let report = receipt.report {
        if let spent = report.inputAmountNative {
          Text("支付 \(spent) \(nativeSymbol)")
            .font(.caption.monospacedDigit())
        }
        if let received = report.outputAmountNative {
          Text("获得 \(received) \(tokenSymbol)")
            .font(.caption.monospacedDigit().weight(.semibold))
        }
        if let gas = report.gasNative {
          Text("Gas \(gas) \(nativeSymbol)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      if !receipt.orderID.isEmpty {
        Text("订单 \(receipt.orderID)")
          .font(.caption.monospaced())
          .textSelection(.enabled)
      }
      if let hash = receipt.transactionHash, let url = explorerURL(hash: hash) {
        Link(destination: url) {
          Label("查看交易 \(shortAddress(hash))", systemImage: "arrow.up.right.square")
        }
        .font(.caption)
      } else if let hash = receipt.transactionHash {
        Text("Tx \(hash)")
          .font(.caption2.monospaced())
          .textSelection(.enabled)
      }
    }
    .padding(13)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      (receipt.isConfirmed ? Color.green : Color.orange).opacity(0.08),
      in: RoundedRectangle(cornerRadius: 7)
    )
  }

  private func prepareTrade(debounced: Bool) async {
    guard canPrepare else { return }
    if debounced {
      do {
        try await Task.sleep(for: .milliseconds(mode == .quick ? 100 : 220))
        try Task.checkCancellation()
      } catch {
        return
      }
    }
    guard let chain = selectedChain, let amount = parsedAmount else { return }
    let operationID = UUID()
    activePreparationID = operationID
    isPreparing = true
    defer {
      if activePreparationID == operationID {
        activePreparationID = nil
        isPreparing = false
      }
    }
    errorMessage = nil
    quotePreview = nil
    preparation = nil
    do {
      let result: ManualBuyPreparation
      if mode == .quick {
        async let pendingInspection = model.inspectManualBuy(
          chain: chain,
          outputToken: context.address,
          skipRugAssessment: true
        )
        let quote = try await model.quoteManualBuy(
          chain: chain,
          outputToken: context.address,
          amountNative: amount,
          slippagePercent: slippagePercent
        )
        try Task.checkCancellation()
        guard activePreparationID == operationID else { return }
        quotePreview = quote
        let inspection = try await pendingInspection
        result = ManualBuyPreparation(
          report: inspection.report,
          quote: quote,
          safety: inspection.safety
        )
      } else {
        result = try await model.prepareManualBuy(
          chain: chain,
          outputToken: context.address,
          amountNative: amount,
          slippagePercent: slippagePercent
        )
      }
      try Task.checkCancellation()
      guard activePreparationID == operationID else { return }
      preparation = result
    } catch is CancellationError {
      return
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func submitBuy(
    authorization: ManualBuyAuthorization,
    confirmedHighRisk: Bool
  ) {
    guard let chain = selectedChain,
      let amount = parsedAmount,
      let preparation
    else { return }
    isSubmitting = true
    errorMessage = nil
    Task {
      do {
        receipt = try await model.executeManualBuy(
          chain: chain,
          outputToken: context.address,
          amountNative: amount,
          slippagePercent: slippagePercent,
          antiMEV: antiMEV,
          preparation: preparation,
          context: context,
          authorization: authorization,
          confirmedHighRisk: confirmedHighRisk
        )
      } catch {
        errorMessage = error.localizedDescription
        quotePreview = nil
        self.preparation = nil
      }
      isSubmitting = false
    }
  }

  private func invalidatePreparation() {
    activePreparationID = nil
    isPreparing = false
    quotePreview = nil
    preparation = nil
    errorMessage = nil
  }

  private var preparationKey: String {
    let wallet = model.walletAddress(for: selectedChain) ?? "none"
    return "\(mode.rawValue)|\(selectedChain?.rawValue ?? "none")|\(wallet)|\(amountText)|\(slippagePercent)"
  }

  private var parsedAmount: Double? {
    let normalized = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: ",", with: ".")
    guard let value = Double(normalized), value.isFinite, value > 0 else { return nil }
    return value
  }

  private var hasMultipleChainCandidates: Bool {
    context.chainCandidates.filter { Self.supportedChains.contains($0.chain) }.count > 1
  }

  private func persistQuickAmount() {
    guard parsedAmount != nil else { return }
    let normalized = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: ",", with: ".")
    UserDefaults.standard.set(normalized, forKey: Self.quickAmountDefaultsKey)
  }

  private var canPrepare: Bool {
    selectedChain != nil
      && parsedAmount != nil
      && model.walletAddress(for: selectedChain) != nil
  }

  private var canSubmitQuick: Bool {
    canPrepare && !model.tradeAutomationConfiguration.emergencyStopped
      && preparation?.safety.allowsQuickBuy == true
  }

  private var configurationNoticeMessage: String? {
    if model.tradeAutomationConfiguration.emergencyStopped {
      return "全局紧急停止已启用，真实买入已禁用。"
    }
    if model.isRefreshingGMGNPortfolio, model.gmgnPortfolioInfo == nil {
      return "正在从当前 API Key 读取按链钱包。"
    }
    if selectedChain != nil, model.walletAddress(for: selectedChain) == nil {
      return "当前 API Key 未返回该网络的钱包；可在交易设置中填写兼容回退钱包。"
    }
    if let state = model.gmgnTradeConfigurationState, state != .ready {
      return state.localizedTitle
    }
    return nil
  }

  private var walletSummary: String {
    guard let wallet = model.walletAddress(for: selectedChain) else {
      return selectedChain == nil ? "等待选择网络" : "该网络没有可用钱包"
    }
    return "钱包 \(shortAddress(wallet))"
  }

  private var standardConfirmationTitle: String {
    if preparation?.safety.requiresAdditionalConfirmation == true {
      return "高风险，仍买入 \(amountText) \(nativeSymbol)"
    }
    return "买入 \(amountText) \(nativeSymbol)"
  }

  private var confirmationSummary: String {
    guard let preparation else { return "交易参数尚未准备完成。" }
    return "\(selectedChain?.localizedTitle ?? "未知网络") · \(walletSummary) · \(context.address) · 滑点 \(slippagePercent)% · 预计获得 \(formattedQuoteOutput(preparation.quote.outputAmount)) · \(preparation.safety.detail)"
  }

  private var tokenTitle: String {
    let preparedSymbol = preparation?.report.token.symbol
    let preparedName = preparation?.report.token.name
    let symbol = (preparedSymbol?.isEmpty == false ? preparedSymbol : context.symbol)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let name = (preparedName?.isEmpty == false ? preparedName : context.name)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !symbol.isEmpty, !name.isEmpty,
      symbol.caseInsensitiveCompare(name) != .orderedSame
    {
      return "\(symbol) · \(name)"
    }
    return symbol.isEmpty ? (name.isEmpty ? "未知代币" : name) : symbol
  }

  private var marketCapUSD: Double? {
    preparation?.report.token.marketCapUSD ?? context.marketCapUSD
  }

  private var liquidityUSD: Double? {
    preparation?.report.token.liquidityUSD ?? context.liquidityUSD
  }

  private var tokenLogoURL: String? {
    preparation?.report.token.logoURL ?? context.logoURL
  }

  private var nativeSymbol: String {
    selectedChain.map(GMGNNativeAsset.symbol(for:)) ?? "原生资产"
  }

  private var tokenSymbol: String {
    let symbol = preparation?.report.token.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
    return symbol?.isEmpty == false ? symbol! : "代币"
  }

  private var supportsAntiMEV: Bool {
    selectedChain.map(GMGNNativeAsset.supportsAntiMEV(on:)) == true
  }

  private var configurationColor: Color {
    switch model.gmgnTradeConfigurationState {
    case .ready: return WxFomoTheme.signal
    case .notConfigured, .executableUnavailable: return .orange
    case .none: return .secondary
    }
  }

  private var tokenLogo: some View {
    Group {
      if let tokenLogoURL,
        let url = URL(string: tokenLogoURL),
        url.scheme == "https"
      {
        AsyncImage(url: url) { phase in
          if let image = phase.image {
            image.resizable().scaledToFill()
          } else {
            logoPlaceholder
          }
        }
      } else {
        logoPlaceholder
      }
    }
    .frame(width: 46, height: 46)
    .clipShape(RoundedRectangle(cornerRadius: 7))
  }

  private var logoPlaceholder: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 7)
        .fill(WxFomoTheme.signal.opacity(0.14))
      Image(systemName: "bitcoinsign.circle.fill")
        .font(.system(size: 23))
        .foregroundStyle(WxFomoTheme.signal)
    }
  }

  private func quoteMetric(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).foregroundStyle(.secondary)
      Text(value).fontWeight(.semibold).lineLimit(1)
    }
  }

  private func safetyColor(_ level: GMGNTradeSafetyLevel) -> Color {
    switch level {
    case .low: return .green
    case .medium: return .orange
    case .high, .blocked: return .red
    }
  }

  private func safetySymbol(_ level: GMGNTradeSafetyLevel) -> String {
    switch level {
    case .low: return "checkmark.shield.fill"
    case .medium: return "exclamationmark.shield.fill"
    case .high, .blocked: return "xmark.shield.fill"
    }
  }

  private func formattedAmount(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...4)))
  }

  private func formattedQuoteOutput(_ raw: String) -> String {
    guard let decimals = preparation?.report.token.decimals ?? context.tokenDecimals,
      let report = GMGNTradeExecutionReport(
        outputTokenDecimals: decimals,
        outputAmount: raw
      ).outputAmountNative
    else { return raw }
    return "\(report) \(tokenSymbol)"
  }

  private func shortAddress(_ value: String) -> String {
    guard value.count > 14 else { return value }
    return "\(value.prefix(7))…\(value.suffix(7))"
  }

  private func formattedUSD(_ value: Double) -> String {
    guard value.isFinite else { return "未返回" }
    if value >= 1_000_000_000 {
      return "$\((value / 1_000_000_000).formatted(.number.precision(.fractionLength(1...2))))B"
    }
    if value >= 1_000_000 {
      return "$\((value / 1_000_000).formatted(.number.precision(.fractionLength(1...2))))M"
    }
    if value >= 1_000 {
      return "$\((value / 1_000).formatted(.number.precision(.fractionLength(1...1))))K"
    }
    return value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
  }

  private func explorerURL(hash: String) -> URL? {
    let host: String
    switch selectedChain {
    case .sol: host = "solscan.io/tx"
    case .eth: host = "etherscan.io/tx"
    case .base: host = "basescan.org/tx"
    case .bsc: host = "bscscan.com/tx"
    default: return nil
    }
    return URL(string: "https://\(host)/\(hash)")
  }

  private static let supportedChains: [GMGNChain] = [.sol, .bsc, .base, .eth, .robinhood]
  private static let quickAmountDefaultsKey = "wxfomo.trade.quick.amount.v1"

  private static func savedQuickAmount() -> String? {
    guard let raw = UserDefaults.standard.string(forKey: quickAmountDefaultsKey),
      let value = Double(raw), value.isFinite, value > 0
    else { return nil }
    return raw
  }

  private static let presets: [Double] = [0.001, 0.005, 0.01, 0.05]
  private static let slippageOptions = [5, 8, 12, 20, 30]
}
