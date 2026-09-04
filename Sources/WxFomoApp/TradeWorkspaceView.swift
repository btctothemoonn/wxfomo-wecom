import AppKit
import SwiftUI
import WxFomoCore

struct TradeWorkspaceView: View {
  @EnvironmentObject private var model: AppModel
  @State private var input = ""
  @State private var mode: ManualBuyMode = .quick
  @State private var isOpeningBuy = false
  @State private var inputError: String?
  @State private var inputPreview: ManualBuyContext?
  @State private var isResolvingInput = false
  @State private var activeInputResolutionID: UUID?
  @State private var quickAmountText = UserDefaults.standard.string(
    forKey: "wxfomo.trade.quick.amount.v1"
  ) ?? "0.01"
  @State private var quickSlippagePercent = UserDefaults.standard.object(
    forKey: "wxfomo.trade.quick.slippage.v1"
  ) as? Int ?? 12
  @State private var quickQuote: GMGNTradeQuote?
  @State private var quickPreparation: ManualBuyPreparation?
  @State private var isPreparingQuickBuy = false
  @State private var isSubmittingQuickBuy = false
  @State private var activeQuickPreparationID: UUID?
  @State private var quickBuyError: String?
  @State private var quickBuyResult: String?
  @State private var historyPage = 1
  @State private var showsSettings = false
  @State private var selectedPortfolioWalletID: String?
  @State private var expandedIntentIDs = Set<String>()

  var body: some View {
    WorkspacePage(title: "交易工作台", subtitle: "输入 CA、核对 GMGN 账户并管理买卖记录") {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 20) {
          accountSection
          buySection
          positionsSection
          historySection
        }
        .padding(22)
      }
      .onAppear {
        model.refreshGMGNTradeConfiguration()
        model.refreshGMGNPortfolio()
        model.refreshTradeAutomationWorkspace()
      }
      .onChange(of: model.gmgnPortfolioInfo?.fetchedAt) { _, _ in
        syncPortfolioSelection()
      }
      .task(id: inputDetectionKey) {
        await resolveInputPreview()
      }
      .task(id: quickPreparationKey) {
        await prepareInlineQuickBuy()
      }
      .onChange(of: quickAmountText) {
        persistQuickBuyPreferences()
        quickBuyError = nil
        quickBuyResult = nil
      }
      .onChange(of: quickSlippagePercent) {
        persistQuickBuyPreferences()
        quickBuyError = nil
        quickBuyResult = nil
      }
      .onChange(of: mode) {
        quickQuote = nil
        quickPreparation = nil
        quickBuyError = nil
        quickBuyResult = nil
      }
      .sheet(isPresented: $showsSettings) {
        TradeAutomationSettingsView(configuration: model.tradeAutomationConfiguration) {
          model.updateTradeAutomationConfiguration($0)
          model.refreshGMGNPortfolio()
        }
      }
    }
  }

  private var accountSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 10) {
        Label("GMGN 账户", systemImage: "wallet.pass")
          .font(.callout.weight(.medium))
        if let portfolio = model.gmgnPortfolioInfo, !portfolio.wallets.isEmpty {
          Text("\(portfolio.wallets.count) 网络 · \(distinctAddressCount(in: portfolio.wallets)) 地址")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text(model.gmgnTradeConfigurationState?.localizedTitle ?? "检查中")
          .font(.caption2.weight(.medium))
          .foregroundStyle(
            model.gmgnTradeConfigurationState == .ready ? Color.green : Color.orange
          )
        Label("IPv4 优先", systemImage: "network.badge.shield.half.filled")
          .font(.caption2.weight(.medium))
          .foregroundStyle(.green)
          .help("wxFomo 为所有 gmgn-cli 请求启用 IPv4 优先；出口 IP 仍须在 GMGN API Key 可信列表中")
        Button { showsSettings = true } label: {
          Image(systemName: "gearshape")
        }
        .buttonStyle(.bordered)
        .help("设置兼容回退钱包与交易限制")
        Button(action: model.refreshGMGNPortfolio) {
          if model.isRefreshingGMGNPortfolio {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .buttonStyle(.bordered)
        .disabled(model.isRefreshingGMGNPortfolio)
        .help("刷新 GMGN 账户")
      }

      if let error = model.gmgnPortfolioError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      }

      if let portfolio = model.gmgnPortfolioInfo {
        if portfolio.wallets.isEmpty {
          Label("当前 GMGN API Key 未返回绑定钱包", systemImage: "wallet.bifold")
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        } else {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
              ForEach(portfolio.wallets) { wallet in
                walletTab(wallet)
              }
            }
          }

          if let wallet = selectedWallet(in: portfolio.wallets) {
            walletDetail(wallet)
          }
        }
        HStack(spacing: 5) {
          Text("更新 \(portfolio.fetchedAt.formatted(date: .omitted, time: .shortened))")
          Text("·")
          Text("交易按网络自动选钱包")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.tertiary)
      } else if model.isRefreshingGMGNPortfolio {
        HStack(spacing: 9) {
          ProgressView().controlSize(.small)
          Text("正在读取 GMGN 账户")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(minHeight: 32)
      } else {
        Text("暂未读取到 GMGN 账户，可稍后刷新。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(minHeight: 32)
      }
    }
    .padding(10)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.46))
  }

  private func walletTab(_ wallet: GMGNLinkedWalletSnapshot) -> some View {
    let isSelected = selectedPortfolioWalletID == wallet.id
      || (selectedPortfolioWalletID == nil && selectedWallet(in: model.gmgnPortfolioInfo?.wallets ?? [])?.id == wallet.id)
    return Button {
      selectedPortfolioWalletID = wallet.id
    } label: {
      VStack(spacing: 4) {
        HStack(spacing: 5) {
          Text(wallet.localizedChainTitle)
            .font(.caption.weight(isSelected ? .semibold : .regular))
          if !wallet.balances.isEmpty {
            Circle()
              .fill(Color.green)
              .frame(width: 5, height: 5)
              .accessibilityLabel("有余额项目")
          }
        }
        Rectangle()
          .fill(isSelected ? WxFomoTheme.signal : Color.clear)
          .frame(height: 2)
      }
      .foregroundStyle(isSelected ? Color.primary : Color.secondary)
      .frame(minWidth: 70, minHeight: 27)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func walletDetail(_ wallet: GMGNLinkedWalletSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "wallet.bifold.fill")
          .foregroundStyle(WxFomoTheme.signal)
        Text(wallet.localizedChainTitle)
          .font(.caption.weight(.semibold))
        Spacer()
        Text(wallet.primaryAddress ?? "地址未返回")
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
        if let address = wallet.primaryAddress {
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address, forType: .string)
          } label: {
            Image(systemName: "doc.on.doc")
          }
          .buttonStyle(.borderless)
          .help("复制钱包地址")
        }
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 6)

      Divider()

      if wallet.balances.isEmpty {
        Label("该网络未返回余额项目", systemImage: "minus.circle")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 9)
          .padding(.vertical, 7)
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 16) {
            ForEach(wallet.balances) { balance in
              balanceRow(balance)
            }
          }
          .padding(.horizontal, 9)
          .padding(.vertical, 6)
        }
      }
    }
    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    }
  }

  private func balanceRow(_ balance: GMGNPortfolioBalanceSnapshot) -> some View {
    HStack(spacing: 5) {
      Text(balance.symbol)
        .font(.caption2.weight(.semibold))
      Text(balance.balance)
        .font(.caption.monospacedDigit())
        .lineLimit(1)
      if let usdValue = balance.usdValue?.trimmingCharacters(in: .whitespacesAndNewlines),
        !usdValue.isEmpty
      {
        Text("$\(usdValue)")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .help(balance.tokenAddress.map { "\(balance.symbol) · \($0)" } ?? balance.symbol)
  }

  private func selectedWallet(
    in wallets: [GMGNLinkedWalletSnapshot]
  ) -> GMGNLinkedWalletSnapshot? {
    if let selectedPortfolioWalletID,
      let selected = wallets.first(where: { $0.id == selectedPortfolioWalletID })
    {
      return selected
    }
    return wallets.first(where: { !$0.balances.isEmpty }) ?? wallets.first
  }

  private func syncPortfolioSelection() {
    guard let wallets = model.gmgnPortfolioInfo?.wallets, !wallets.isEmpty else {
      selectedPortfolioWalletID = nil
      return
    }
    if let selectedPortfolioWalletID,
      wallets.contains(where: { $0.id == selectedPortfolioWalletID })
    {
      return
    }
    selectedPortfolioWalletID = wallets.first(where: { !$0.balances.isEmpty })?.id
      ?? wallets.first?.id
  }

  private func distinctAddressCount(in wallets: [GMGNLinkedWalletSnapshot]) -> Int {
    Set(wallets.compactMap(\.primaryAddress).map { address in
      address.hasPrefix("0x") ? address.lowercased() : address
    }).count
  }

  private var buySection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Label("CA 买入", systemImage: "scope")
            .font(.headline)
          Text("裸 0x 地址优先由 GMGN 识别；未命中才用 DexScreener")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Picker("买入模式", selection: $mode) {
          ForEach(ManualBuyMode.allCases) { option in
            Text(option.title).tag(option)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 170)
      }

      HStack(spacing: 10) {
        Image(systemName: "link")
          .foregroundStyle(.secondary)
        TextField("粘贴 CA 或包含 CA 的链接", text: $input)
          .textFieldStyle(.plain)
          .onSubmit(primaryBuyAction)
        if mode == .quick {
          Divider().frame(height: 22)
          TextField("0.01", text: $quickAmountText)
            .textFieldStyle(.plain)
            .font(.callout.monospacedDigit().weight(.semibold))
            .multilineTextAlignment(.trailing)
            .frame(width: 66)
          Text(nativeSymbol(inputPreview?.suggestedChain))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(minWidth: 28)
          Menu {
            Section("常用金额") {
              ForEach(Self.quickAmountPresets, id: \.self) { value in
                Button(formattedQuickAmount(value)) {
                  quickAmountText = formattedQuickAmount(value)
                }
              }
            }
            Section("滑点") {
              ForEach(Self.quickSlippageOptions, id: \.self) { value in
                Button("\(value)%") { quickSlippagePercent = value }
              }
            }
          } label: {
            Image(systemName: "slider.horizontal.3")
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .help("常用金额与滑点；当前滑点 \(quickSlippagePercent)%")
        }
        Button(action: primaryBuyAction) {
          if primaryBuyIsBusy {
            ProgressView().controlSize(.small).frame(width: 82)
          } else {
            Label(
              primaryBuyButtonTitle,
              systemImage: mode == .quick ? "bolt.fill" : "arrow.right"
            )
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(mode == .quick ? .orange : WxFomoTheme.signal)
        .disabled(
          input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !primaryBuyIsEnabled
        )
      }
      .padding(.leading, 12)
      .padding(.trailing, 6)
      .padding(.vertical, 6)
      .background(Color(nsColor: .textBackgroundColor))
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      }

      if let inputError {
        Label(inputError, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
      } else if isResolvingInput {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("正在识别网络、代币和交易池")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if let inputPreview {
        inputPreviewView(inputPreview)
        if mode == .quick { inlineQuickBuyStatus(inputPreview) }
      }

      if let quickBuyResult, inputPreview == nil {
        Label(quickBuyResult, systemImage: "checkmark.circle.fill")
          .font(.caption.weight(.medium))
          .foregroundStyle(.green)
      }
    }
    .padding(14)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.46))
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(mode == .quick ? Color.orange : WxFomoTheme.signal)
        .frame(width: 3)
    }
  }

  @ViewBuilder
  private var positionsSection: some View {
    if !sellablePositions.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text("已买入代币").font(.headline)
          Text("卖出时会读取 GMGN 最新余额，不使用历史买入数量代替当前持仓")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        VStack(spacing: 0) {
          ForEach(Array(sellablePositions.enumerated()), id: \.element.id) { index, intent in
            HStack(spacing: 10) {
              Image(systemName: "chart.line.uptrend.xyaxis.circle.fill")
                .foregroundStyle(WxFomoTheme.signal)
                .frame(width: 22)
              VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                  Text(intent.tokenSymbol ?? intent.tokenName ?? "未知代币")
                    .font(.callout.weight(.semibold))
                  Text(intent.chain?.localizedTitle ?? "网络待确认")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                if let amount = intent.executionReport?.outputAmountNative {
                  Text("最近成交获得 \(amount) \(intent.tokenSymbol ?? "代币")")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
              }
              Spacer()
              Button {
                model.presentManualSell(for: intent)
              } label: {
                Label("卖出", systemImage: "arrow.up.right")
              }
              .buttonStyle(.borderedProminent)
              .tint(.red)
              .controlSize(.small)
            }
            .padding(11)
            if index < sellablePositions.count - 1 { Divider() }
          }
        }
        .overlay {
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
      }
    }
  }

  private var sellablePositions: [TradeIntent] {
    var decided = Set<String>()
    var result: [TradeIntent] = []
    for intent in model.tradeIntents
      where intent.state == .confirmed || intent.state == .unprotectedPosition
    {
      let key = positionKey(intent)
      if intent.resolvedSide == .sell {
        if intent.sellPercent == 100 { decided.insert(key) }
        continue
      }
      guard !decided.contains(key) else { continue }
      decided.insert(key)
      result.append(intent)
    }
    return result
  }

  private func positionKey(_ intent: TradeIntent) -> String {
    let address = intent.chain == .sol ? intent.tokenAddress : intent.tokenAddress.lowercased()
    return "\(intent.chain?.rawValue ?? "unknown")|\(address)"
  }

  private var historySection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("手动交易记录").font(.headline)
          Text("每页 10 条；显示交易工作台产生的手动买入与卖出记录")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button(action: model.refreshTradeAutomationWorkspace) {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .help("刷新手动交易记录")
      }

      if let error = model.tradeAutomationError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      }

      if manualIntents.isEmpty {
        Text("暂无手动交易记录")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 72)
      } else {
        VStack(spacing: 0) {
          ForEach(Array(pagedManualIntents.enumerated()), id: \.element.id) { index, intent in
            intentRow(intent)
            if index < pagedManualIntents.count - 1 { Divider() }
          }
        }
        .overlay {
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        PaginationBar(
          totalCount: manualIntents.count,
          currentPage: $historyPage,
          showsTopDivider: false
        )
      }
    }
  }

  private var manualIntents: [TradeIntent] {
    model.tradeIntents.filter { $0.ruleID == "manual-buy" || $0.ruleID == "manual-sell" }
  }

  private var pagedManualIntents: [TradeIntent] {
    manualIntents.pageItems(page: historyPage)
  }

  private func intentRow(_ intent: TradeIntent) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: stateSymbol(intent.state))
        .foregroundStyle(stateColor(intent.state))
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Text(intent.resolvedSide.localizedTitle)
            .font(.caption2.weight(.bold))
            .foregroundStyle(intent.resolvedSide == .buy ? Color.green : Color.red)
          Text(intent.tokenSymbol ?? intent.tokenName ?? "未知代币")
            .font(.callout.weight(.semibold))
          Text(intent.chain?.localizedTitle ?? "网络待确认")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
          Text(intent.state.localizedTitle)
            .font(.caption2.weight(.medium))
            .foregroundStyle(stateColor(intent.state))
        }
        Text(shortAddress(intent.tokenAddress))
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
        Text("提交 \((intent.submittedAt ?? intent.createdAt).formatted(date: .abbreviated, time: .standard))")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
        if let confirmedAt = intent.confirmedAt {
          Text("确认 \(confirmedAt.formatted(date: .abbreviated, time: .standard))")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
        if let report = intent.executionReport {
          Text(executionSummary(intent, report: report))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.primary)
          DisclosureGroup(
            isExpanded: Binding(
              get: { expandedIntentIDs.contains(intent.id) },
              set: { expanded in
                if expanded { expandedIntentIDs.insert(intent.id) }
                else { expandedIntentIDs.remove(intent.id) }
              }
            )
          ) {
            executionDetails(intent, report: report)
              .padding(.top, 5)
          } label: {
            Text("成交明细")
              .font(.caption2.weight(.medium))
          }
        } else if let reason = intent.failureReason {
          Text(reason)
            .font(.caption2)
            .foregroundStyle(stateColor(intent.state))
            .lineLimit(2)
        }
      }
      Spacer()
      HStack(spacing: 9) {
        if intent.orderID != nil {
          Button { model.refreshTradeIntent(intent) } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.borderless)
          .help(intent.executionReport == nil ? "重新拉取成交明细" : "刷新订单状态和明细")
        }
        if intent.resolvedSide == .buy, intent.state == .confirmed {
          Button { model.presentManualSell(for: intent) } label: {
            Label("卖出", systemImage: "arrow.up.right")
          }
          .buttonStyle(.borderedProminent)
          .tint(.red)
          .controlSize(.small)
        }
        Button { model.presentManualBuy(for: intent) } label: {
          Image(systemName: "arrow.clockwise.circle")
        }
        .buttonStyle(.borderless)
        .help("按本次代币重新打开买入面板")
        .disabled(intent.state == .submitting || intent.state == .pending)
      }
    }
    .padding(12)
  }

  private func executionSummary(
    _ intent: TradeIntent,
    report: GMGNTradeExecutionReport
  ) -> String {
    let input = report.inputAmountNative ?? report.inputAmount ?? "--"
    let output = report.outputAmountNative ?? report.outputAmount ?? "--"
    if intent.resolvedSide == .sell {
      return "卖出 \(input) \(intent.tokenSymbol ?? "代币") → 获得 \(output) \(nativeSymbol(intent.chain))"
    }
    return "支付 \(input) \(nativeSymbol(intent.chain)) → 获得 \(output) \(intent.tokenSymbol ?? "代币")"
  }

  private func executionDetails(
    _ intent: TradeIntent,
    report: GMGNTradeExecutionReport
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if let priceUSD = report.priceUSD {
        detailLine("成交单价", "$\(priceUSD)")
      } else if let price = report.price {
        detailLine("成交价格", price)
      }
      if let gas = report.gasNative {
        let usd = report.gasUSD.map { " · $\($0)" } ?? ""
        detailLine("Gas", "\(gas) \(nativeSymbol(intent.chain))\(usd)")
      }
      if let marketCap = intent.marketSnapshot?.marketCapUSD {
        detailLine("提示时市值", formattedUSD(marketCap))
      }
      if let height = report.height {
        detailLine("成交区块", String(height))
      }
      if let orderID = intent.orderID {
        detailLine("订单号", orderID)
      }
      if let hash = intent.transactionHash, let url = explorerURL(hash: hash, chain: intent.chain) {
        Link(destination: url) {
          Label("查看 Tx \(shortAddress(hash))", systemImage: "arrow.up.right.square")
        }
        .font(.caption2)
      } else if let hash = intent.transactionHash {
        detailLine("Tx", hash)
      }
    }
    .textSelection(.enabled)
  }

  private func detailLine(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Text(label)
        .foregroundStyle(.secondary)
        .frame(width: 64, alignment: .leading)
      Text(value)
        .font(.caption2.monospacedDigit())
        .lineLimit(2)
        .truncationMode(.middle)
    }
    .font(.caption2)
  }

  private func explorerURL(hash: String, chain: GMGNChain?) -> URL? {
    let host: String
    switch chain {
    case .sol: host = "solscan.io/tx"
    case .eth: host = "etherscan.io/tx"
    case .base: host = "basescan.org/tx"
    case .bsc: host = "bscscan.com/tx"
    case .robinhood, .none: return nil
    }
    return URL(string: "https://\(host)/\(hash)")
  }

  private var quickParsedAmount: Double? {
    let normalized = quickAmountText.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: ",", with: ".")
    guard let value = Double(normalized), value.isFinite, value > 0 else { return nil }
    return value
  }

  private var quickPreparationKey: String {
    let previewID = inputPreview?.id.uuidString ?? "none"
    let wallet = model.walletAddress(for: inputPreview?.suggestedChain) ?? "none"
    return "\(mode.rawValue)|\(previewID)|\(wallet)|\(quickAmountText)|\(quickSlippagePercent)"
  }

  private var primaryBuyIsBusy: Bool {
    mode == .quick
      ? isResolvingInput || isPreparingQuickBuy || isSubmittingQuickBuy
      : isResolvingInput || isOpeningBuy
  }

  private var primaryBuyIsEnabled: Bool {
    if mode == .standard {
      return !isResolvingInput && !isOpeningBuy
    }
    guard !isResolvingInput, !isPreparingQuickBuy, !isSubmittingQuickBuy,
      quickParsedAmount != nil,
      let preparation = quickPreparation
    else { return false }
    if preparation.safety.level == .high { return true }
    return preparation.safety.allowsQuickBuy
  }

  private var primaryBuyButtonTitle: String {
    guard mode == .quick else { return "普通买入" }
    if quickPreparation?.safety.level == .high { return "普通复核" }
    if quickPreparation?.safety.level == .blocked { return "已拦截" }
    return "买入"
  }

  private func primaryBuyAction() {
    guard mode == .quick else {
      openBuy()
      return
    }
    guard let preview = inputPreview, let preparation = quickPreparation else { return }
    if preparation.safety.level == .high {
      model.presentManualBuy(
        context: copiedManualBuyContext(
          preview,
          mode: .standard,
          suggestedAmount: quickParsedAmount
        )
      )
      return
    }
    executeInlineQuickBuy(preview: preview, preparation: preparation)
  }

  private func prepareInlineQuickBuy() async {
    guard mode == .quick,
      let preview = inputPreview,
      self.preview(preview, matches: input, mode: .quick),
      let chain = preview.suggestedChain,
      let amount = quickParsedAmount,
      model.walletAddress(for: chain) != nil
    else {
      activeQuickPreparationID = nil
      isPreparingQuickBuy = false
      quickQuote = nil
      quickPreparation = nil
      return
    }

    let operationID = UUID()
    activeQuickPreparationID = operationID
    isPreparingQuickBuy = true
    quickQuote = nil
    quickPreparation = nil
    quickBuyError = nil
    defer {
      if activeQuickPreparationID == operationID {
        activeQuickPreparationID = nil
        isPreparingQuickBuy = false
      }
    }
    do {
      async let pendingInspection = model.inspectManualBuy(
        chain: chain,
        outputToken: preview.address,
        skipRugAssessment: true
      )
      let quote = try await model.quoteManualBuy(
        chain: chain,
        outputToken: preview.address,
        amountNative: amount,
        slippagePercent: quickSlippagePercent
      )
      try Task.checkCancellation()
      guard activeQuickPreparationID == operationID else { return }
      quickQuote = quote

      let inspection = try await pendingInspection
      try Task.checkCancellation()
      guard activeQuickPreparationID == operationID else { return }
      quickPreparation = ManualBuyPreparation(
        report: inspection.report,
        quote: quote,
        safety: inspection.safety
      )
    } catch is CancellationError {
      return
    } catch {
      guard activeQuickPreparationID == operationID else { return }
      quickBuyError = error.localizedDescription
    }
  }

  private func executeInlineQuickBuy(
    preview: ManualBuyContext,
    preparation: ManualBuyPreparation
  ) {
    guard let chain = preview.suggestedChain,
      let amount = quickParsedAmount,
      preparation.safety.allowsQuickBuy,
      !isSubmittingQuickBuy
    else { return }
    isSubmittingQuickBuy = true
    quickBuyError = nil
    quickBuyResult = nil
    Task {
      defer { isSubmittingQuickBuy = false }
      do {
        let receipt = try await model.executeManualBuy(
          chain: chain,
          outputToken: preview.address,
          amountNative: amount,
          slippagePercent: quickSlippagePercent,
          antiMEV: GMGNNativeAsset.supportsAntiMEV(on: chain),
          preparation: preparation,
          context: preview,
          authorization: .quickBuyButton,
          confirmedHighRisk: false
        )
        let token = previewTokenTitle(preview)
        quickBuyResult = receipt.isConfirmed
          ? "\(token) 买入已确认 · 订单 \(receipt.orderID)"
          : "\(token) 订单已提交 · \(receipt.status)"
        input = ""
        inputPreview = nil
        quickQuote = nil
        quickPreparation = nil
      } catch {
        quickBuyError = error.localizedDescription
        quickQuote = nil
        quickPreparation = nil
      }
    }
  }

  private func copiedManualBuyContext(
    _ source: ManualBuyContext,
    mode: ManualBuyMode,
    suggestedAmount: Double?
  ) -> ManualBuyContext {
    ManualBuyContext(
      address: source.address,
      suggestedChain: source.suggestedChain,
      intentID: source.intentID,
      suggestedAmountNative: suggestedAmount,
      suggestedSlippagePercent: quickSlippagePercent,
      symbol: source.symbol,
      name: source.name,
      tokenDecimals: source.tokenDecimals,
      logoURL: source.logoURL,
      marketCapUSD: source.marketCapUSD,
      liquidityUSD: source.liquidityUSD,
      sourceTitle: source.sourceTitle,
      mentionSummary: source.mentionSummary,
      sourceEventIDs: source.sourceEventIDs,
      sourceGroups: source.sourceGroups,
      mode: mode,
      chainCandidates: source.chainCandidates,
      chainDetectionMessage: source.chainDetectionMessage
    )
  }

  private func persistQuickBuyPreferences() {
    if quickParsedAmount != nil {
      let normalized = quickAmountText.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: ",", with: ".")
      UserDefaults.standard.set(normalized, forKey: "wxfomo.trade.quick.amount.v1")
    }
    UserDefaults.standard.set(
      quickSlippagePercent,
      forKey: "wxfomo.trade.quick.slippage.v1"
    )
  }

  private func openBuy() {
    guard !isOpeningBuy, !isResolvingInput else { return }
    let submitted = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !submitted.isEmpty else { return }
    if let inputPreview, preview(inputPreview, matches: submitted, mode: mode) {
      model.presentManualBuy(context: inputPreview)
      input = ""
      self.inputPreview = nil
      inputError = nil
      return
    }
    isOpeningBuy = true
    inputError = nil
    Task {
      defer { isOpeningBuy = false }
      do {
        try await model.presentManualBuy(rawInput: submitted, mode: mode)
        input = ""
      } catch {
        inputError = error.localizedDescription
      }
    }
  }

  private var inputDetectionKey: String {
    "\(mode.rawValue)|\(input.trimmingCharacters(in: .whitespacesAndNewlines))"
  }

  private func resolveInputPreview() async {
    let submitted = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard CryptoAddressDetector.matches(in: submitted).count == 1 else {
      activeInputResolutionID = nil
      isResolvingInput = false
      inputPreview = nil
      inputError = nil
      return
    }

    let resolutionID = UUID()
    activeInputResolutionID = resolutionID
    isResolvingInput = true
    inputPreview = nil
    inputError = nil
    do {
      let context = try await model.resolveManualBuyContext(rawInput: submitted, mode: mode)
      try Task.checkCancellation()
      guard activeInputResolutionID == resolutionID else { return }
      inputPreview = context
    } catch is CancellationError {
      return
    } catch {
      guard activeInputResolutionID == resolutionID else { return }
      inputError = error.localizedDescription
      inputPreview = nil
    }
    if activeInputResolutionID == resolutionID {
      activeInputResolutionID = nil
      isResolvingInput = false
    }
  }

  private func preview(
    _ preview: ManualBuyContext,
    matches rawInput: String,
    mode: ManualBuyMode
  ) -> Bool {
    let matches = CryptoAddressDetector.matches(in: rawInput)
    guard preview.mode == mode, matches.count == 1, let match = matches.first else { return false }
    return match.family == .evm
      ? preview.address.caseInsensitiveCompare(match.normalizedAddress) == .orderedSame
      : preview.address == match.normalizedAddress
  }

  private func inputPreviewView(_ preview: ManualBuyContext) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: preview.suggestedChain == nil ? "questionmark.circle" : "checkmark.circle.fill")
        .foregroundStyle(preview.suggestedChain == nil ? Color.orange : Color.green)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Text(previewTokenTitle(preview))
            .font(.callout.weight(.semibold))
          Text(preview.suggestedChain?.localizedTitle ?? "网络待选择")
            .font(.caption.weight(.medium))
            .foregroundStyle(preview.suggestedChain == nil ? Color.orange : Color.secondary)
          if let marketCapUSD = preview.marketCapUSD {
            Text("市值 \(formattedUSD(marketCapUSD))")
          }
          if let liquidityUSD = preview.liquidityUSD {
            Text("池子 \(formattedUSD(liquidityUSD))")
          }
        }
        .font(.caption)
        if let message = preview.chainDetectionMessage {
          Text(message)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        if preview.suggestedChain == nil, !preview.chainCandidates.isEmpty {
          Text("候选：\(preview.chainCandidates.map { $0.chain.localizedTitle }.joined(separator: " / "))")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 12)
      if let chain = preview.suggestedChain {
        if let wallet = model.walletAddress(for: chain) {
          Label(shortAddress(wallet), systemImage: "wallet.pass")
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
        } else {
          Label("无该链钱包", systemImage: "exclamationmark.triangle")
            .font(.caption2)
            .foregroundStyle(.orange)
        }
      }
    }
    .padding(.top, 2)
  }

  @ViewBuilder
  private func inlineQuickBuyStatus(_ preview: ManualBuyContext) -> some View {
    if quickParsedAmount == nil {
      Label("请输入有效买入金额", systemImage: "exclamationmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.red)
    } else if isPreparingQuickBuy {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        if let quickQuote {
          Text("预计 \(formattedQuickOutput(quickQuote, preview: preview))")
            .fontWeight(.medium)
          Text("蜜罐检查中 · Rug 已跳过")
            .foregroundStyle(.tertiary)
        } else {
          Text("正在获取实时报价")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    } else if let quickBuyError {
      Label(quickBuyError, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.red)
    } else if let preparation = quickPreparation {
      HStack(spacing: 9) {
        Label(
          preparation.safety.title,
          systemImage: quickSafetySymbol(preparation.safety.level)
        )
        .foregroundStyle(quickSafetyColor(preparation.safety.level))
        Text("支付 \(quickAmountText) \(nativeSymbol(preview.suggestedChain))")
        Text("预计 \(formattedQuickOutput(preparation))")
        Text("滑点 \(quickSlippagePercent)%")
          .foregroundStyle(.secondary)
        Spacer()
        Text(preparation.quote.quotedAt, style: .time)
          .foregroundStyle(.tertiary)
      }
      .font(.caption.monospacedDigit())
      .help(preparation.safety.detail)
    }
  }

  private func formattedQuickOutput(_ preparation: ManualBuyPreparation) -> String {
    formattedQuickOutput(
      preparation.quote,
      decimals: preparation.report.token.decimals,
      symbol: preparation.report.token.symbol
    )
  }

  private func formattedQuickOutput(
    _ quote: GMGNTradeQuote,
    preview: ManualBuyContext
  ) -> String {
    formattedQuickOutput(quote, decimals: preview.tokenDecimals, symbol: preview.symbol)
  }

  private func formattedQuickOutput(
    _ quote: GMGNTradeQuote,
    decimals: Int?,
    symbol: String?
  ) -> String {
    let raw = quote.outputAmount
    let amount = GMGNTradeExecutionReport(
      outputTokenDecimals: decimals,
      outputAmount: raw
    ).outputAmountNative ?? raw
    let normalizedSymbol = symbol?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return normalizedSymbol.isEmpty ? amount : "\(amount) \(normalizedSymbol)"
  }

  private func quickSafetySymbol(_ level: GMGNTradeSafetyLevel) -> String {
    switch level {
    case .low: return "checkmark.shield.fill"
    case .medium: return "exclamationmark.shield.fill"
    case .high, .blocked: return "xmark.shield.fill"
    }
  }

  private func quickSafetyColor(_ level: GMGNTradeSafetyLevel) -> Color {
    switch level {
    case .low: return .green
    case .medium, .high: return .orange
    case .blocked: return .red
    }
  }

  private func previewTokenTitle(_ preview: ManualBuyContext) -> String {
    let symbol = preview.symbol?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let name = preview.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !symbol.isEmpty { return symbol }
    if !name.isEmpty { return name }
    return shortAddress(preview.address)
  }

  private func formattedUSD(_ value: Double) -> String {
    if value >= 1_000_000_000 {
      return "$" + (value / 1_000_000_000).formatted(.number.precision(.fractionLength(1...2))) + "B"
    }
    if value >= 1_000_000 {
      return "$" + (value / 1_000_000).formatted(.number.precision(.fractionLength(1...2))) + "M"
    }
    if value >= 1_000 {
      return "$" + (value / 1_000).formatted(.number.precision(.fractionLength(1...2))) + "K"
    }
    return value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
  }

  private func shortAddress(_ value: String) -> String {
    guard value.count > 18 else { return value }
    return "\(value.prefix(9))...\(value.suffix(7))"
  }

  private func nativeSymbol(_ chain: GMGNChain?) -> String {
    switch chain {
    case .sol: return "SOL"
    case .bsc: return "BNB"
    case .eth, .base, .robinhood: return "ETH"
    case nil: return ""
    }
  }

  private func formattedQuickAmount(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...4)))
  }

  private func stateSymbol(_ state: TradeIntentState) -> String {
    switch state {
    case .confirmed: return "checkmark.circle.fill"
    case .failed, .rejected, .unprotectedPosition: return "exclamationmark.triangle.fill"
    case .submitting, .pending: return "clock.arrow.circlepath"
    default: return "circle.dotted"
    }
  }

  private func stateColor(_ state: TradeIntentState) -> Color {
    switch state {
    case .confirmed: return .green
    case .failed, .rejected, .unprotectedPosition: return .red
    case .submitting, .pending: return .orange
    default: return .secondary
    }
  }

  private static let quickAmountPresets: [Double] = [0.001, 0.005, 0.01, 0.05]
  private static let quickSlippageOptions = [5, 8, 12, 20, 30]
}
