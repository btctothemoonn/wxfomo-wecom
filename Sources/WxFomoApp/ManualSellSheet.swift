import SwiftUI
import WxFomoCore

struct ManualSellSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss

  let context: ManualSellContext

  @State private var mode: ManualBuyMode
  @State private var percent = 100
  @State private var slippagePercent: Int
  @State private var antiMEV = true
  @State private var preparation: ManualSellPreparation?
  @State private var isPreparing = false
  @State private var isSubmitting = false
  @State private var errorMessage: String?
  @State private var receipt: GMGNTradeOrderSnapshot?
  @State private var showsConfirmation = false

  init(context: ManualSellContext) {
    self.context = context
    _mode = State(initialValue: context.mode)
    _slippagePercent = State(initialValue: context.suggestedSlippagePercent)
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          tokenSummary
          tradeParameters
          if isPreparing { preparingView }
          if let preparation { quoteSummary(preparation) }
          if let receipt { receiptView(receipt) }
          if let errorMessage { errorView(errorMessage) }
        }
        .padding(20)
      }
      Divider()
      footer
    }
    .frame(width: 590, height: 560)
    .onAppear {
      model.refreshGMGNTradeConfiguration()
      model.refreshGMGNPortfolio()
    }
    .onChange(of: percent) { preparation = nil }
    .onChange(of: slippagePercent) { preparation = nil }
    .onChange(of: antiMEV) { preparation = nil }
    .task(id: preparationKey) {
      guard receipt == nil else { return }
      await prepareSell(debounced: true)
    }
    .confirmationDialog(
      "确认提交真实卖出？",
      isPresented: $showsConfirmation,
      titleVisibility: .visible
    ) {
      Button("确认卖出 \(percent)%", role: .destructive) {
        submitSell(authorization: .standardConfirmation)
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text(confirmationSummary)
    }
  }

  private var header: some View {
    HStack(spacing: 11) {
      Image(systemName: mode == .quick ? "bolt.fill" : "arrow.up.right.circle.fill")
        .font(.system(size: 21, weight: .semibold))
        .foregroundStyle(mode == .quick ? Color.orange : Color.red)
        .frame(width: 26)
      VStack(alignment: .leading, spacing: 2) {
        Text(mode == .quick ? "快速卖出" : "普通卖出")
          .font(.headline)
        Text("\(context.chain.localizedTitle) · \(tokenTitle)")
          .font(.caption)
          .foregroundStyle(.secondary)
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
          Text(tokenTitle).font(.title3.weight(.semibold))
          Text(context.chain.localizedTitle)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        Text(context.tokenAddress)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
        Label(walletSummary, systemImage: "wallet.pass")
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(Color.red.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
  }

  private var tradeParameters: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("卖出比例").font(.callout.weight(.semibold))
        Spacer()
        Text("\(percent)%").font(.callout.monospacedDigit().weight(.semibold))
      }
      Picker("卖出比例", selection: $percent) {
        ForEach(Self.percentOptions, id: \.self) { value in
          Text("\(value)%").tag(value)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      HStack(spacing: 10) {
        Menu {
          ForEach(Self.slippageOptions, id: \.self) { value in
            Button("\(value)%") { slippagePercent = value }
          }
        } label: {
          Label("滑点 \(slippagePercent)%", systemImage: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        if GMGNNativeAsset.supportsAntiMEV(on: context.chain) {
          Toggle("Anti-MEV", isOn: $antiMEV)
            .toggleStyle(.checkbox)
        } else {
          Label("GMGN 标准路由", systemImage: "point.3.connected.trianglepath.dotted")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text(model.gmgnTradeConfigurationState?.localizedTitle ?? "检查配置中")
          .font(.caption)
          .foregroundStyle(model.gmgnTradeConfigurationState == .ready ? Color.green : Color.orange)
      }
      .font(.caption)
    }
    .padding(13)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.68), in: RoundedRectangle(cornerRadius: 7))
  }

  private var preparingView: some View {
    HStack(spacing: 10) {
      ProgressView().controlSize(.small)
      Text("正在读取最新余额并获取卖出报价")
        .font(.callout.weight(.medium))
      Spacer()
    }
    .padding(13)
    .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
  }

  private func quoteSummary(_ value: ManualSellPreparation) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("卖出报价已就绪", systemImage: "checkmark.circle.fill")
          .font(.callout.weight(.semibold))
          .foregroundStyle(.green)
        Spacer()
        Text(value.quote.quotedAt, style: .time)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 24) {
        quoteMetric("当前余额", "\(value.balance.balance) \(tokenSymbol)")
        quoteMetric("预计卖出", "\(estimatedSellAmount(value.balance.balance)) \(tokenSymbol)")
        quoteMetric("预计获得", formattedNativeAmount(value.quote.outputAmount))
      }
      .font(.caption.monospacedDigit())
    }
    .padding(13)
    .background(Color.green.opacity(0.065), in: RoundedRectangle(cornerRadius: 7))
  }

  private var footer: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(mode == .quick ? "点击立即卖出后直接提交" : "余额与报价 30 秒内有效")
          .font(.caption.weight(.medium))
        Text("卖出按 GMGN 提交时的最新余额比例执行")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if receipt != nil {
        Button("完成") { dismiss() }.buttonStyle(.borderedProminent)
      } else if mode == .quick {
        Button {
          submitSell(authorization: .quickSellButton)
        } label: {
          if isPreparing || isSubmitting {
            ProgressView().controlSize(.small)
          } else {
            Label("立即卖出 \(percent)%", systemImage: "bolt.fill")
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.red)
        .disabled(!canSubmit || isPreparing || isSubmitting)
      } else {
        Button("确认卖出 \(percent)%") { showsConfirmation = true }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .tint(.red)
          .disabled(!canSubmit || isSubmitting)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  private func prepareSell(debounced: Bool) async {
    guard model.gmgnTradeConfigurationState == .ready,
      !model.tradeAutomationConfiguration.emergencyStopped
    else { return }
    if debounced {
      do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
    }
    isPreparing = true
    preparation = nil
    errorMessage = nil
    do {
      preparation = try await model.prepareManualSell(
        context: context,
        percent: percent,
        slippagePercent: slippagePercent
      )
    } catch is CancellationError {
      return
    } catch {
      errorMessage = error.localizedDescription
    }
    isPreparing = false
  }

  private func submitSell(authorization: ManualSellAuthorization) {
    guard let preparation, !isSubmitting else { return }
    isSubmitting = true
    errorMessage = nil
    Task {
      defer { isSubmitting = false }
      do {
        receipt = try await model.executeManualSell(
          context: context,
          percent: percent,
          slippagePercent: slippagePercent,
          antiMEV: antiMEV,
          preparation: preparation,
          authorization: authorization
        )
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func receiptView(_ value: GMGNTradeOrderSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Label(
        value.isConfirmed ? "卖出已确认" : "卖出订单处理中",
        systemImage: value.isConfirmed ? "checkmark.circle.fill" : "clock.arrow.circlepath"
      )
      .font(.headline)
      .foregroundStyle(value.isConfirmed ? Color.green : Color.orange)
      if let report = value.report {
        if let sold = report.inputAmountNative {
          Text("卖出 \(sold) \(tokenSymbol)").font(.caption.monospacedDigit())
        }
        if let received = report.outputAmountNative {
          Text("获得 \(received) \(nativeSymbol)")
            .font(.caption.monospacedDigit().weight(.semibold))
        }
        if let gas = report.gasNative {
          Text("Gas \(gas) \(nativeSymbol)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      if !value.orderID.isEmpty {
        Text("订单 \(value.orderID)")
          .font(.caption.monospaced())
          .textSelection(.enabled)
      }
      if let hash = value.transactionHash, let url = explorerURL(hash: hash) {
        Link(destination: url) {
          Label("查看交易 \(shortAddress(hash))", systemImage: "arrow.up.right.square")
        }
        .font(.caption)
      } else if let hash = value.transactionHash {
        Text("Tx \(hash)").font(.caption2.monospaced()).textSelection(.enabled)
      }
    }
    .padding(13)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background((value.isConfirmed ? Color.green : Color.orange).opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
  }

  private func errorView(_ message: String) -> some View {
    Label(message, systemImage: "exclamationmark.triangle.fill")
      .font(.caption)
      .foregroundStyle(.red)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
  }

  private var preparationKey: String {
    "\(mode.rawValue)|\(percent)|\(slippagePercent)|\(antiMEV)|\(model.gmgnTradeConfigurationState?.rawValue ?? "")"
  }

  private var canSubmit: Bool {
    preparation != nil && model.gmgnTradeConfigurationState == .ready
      && !model.tradeAutomationConfiguration.emergencyStopped
  }

  private var confirmationSummary: String {
    guard let preparation else { return "卖出参数尚未准备完成。" }
    return "\(context.chain.localizedTitle) · 卖出 \(percent)% \(tokenSymbol) · 预计获得 \(formattedNativeAmount(preparation.quote.outputAmount)) · 滑点 \(slippagePercent)%"
  }

  private var tokenTitle: String {
    let name = context.tokenName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let symbol = context.tokenSymbol?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !name.isEmpty, !symbol.isEmpty, name != symbol { return "\(name) · \(symbol)" }
    if !symbol.isEmpty { return symbol }
    if !name.isEmpty { return name }
    return shortAddress(context.tokenAddress)
  }

  private var tokenSymbol: String {
    let value = context.tokenSymbol?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? "代币" : value
  }

  private var nativeSymbol: String { GMGNNativeAsset.symbol(for: context.chain) }

  private var walletSummary: String {
    (model.walletAddress(for: context.chain) ?? context.walletAddress).map(shortAddress)
      ?? "当前网络没有 GMGN 钱包"
  }

  private var tokenLogo: some View {
    Group {
      if let value = context.tokenLogoURL, let url = URL(string: value), url.scheme == "https" {
        AsyncImage(url: url) { phase in
          if let image = phase.image { image.resizable().scaledToFill() } else { logoPlaceholder }
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
      RoundedRectangle(cornerRadius: 7).fill(Color.red.opacity(0.1))
      Image(systemName: "bitcoinsign.circle.fill")
        .font(.system(size: 23))
        .foregroundStyle(.red)
    }
  }

  private func quoteMetric(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).foregroundStyle(.secondary)
      Text(value).fontWeight(.semibold).lineLimit(1)
    }
  }

  private func estimatedSellAmount(_ balance: String) -> String {
    guard let value = Decimal(string: balance, locale: Locale(identifier: "en_US_POSIX")) else {
      return balance
    }
    return NSDecimalNumber(decimal: value * Decimal(percent) / 100).stringValue
  }

  private func formattedNativeAmount(_ raw: String) -> String {
    let decimals = context.chain == .sol ? 9 : 18
    let amount = GMGNTradeExecutionReport(
      outputTokenDecimals: decimals,
      outputAmount: raw
    ).outputAmountNative ?? raw
    return "\(amount) \(nativeSymbol)"
  }

  private func shortAddress(_ value: String) -> String {
    guard value.count > 14 else { return value }
    return "\(value.prefix(7))...\(value.suffix(7))"
  }

  private func explorerURL(hash: String) -> URL? {
    let host: String
    switch context.chain {
    case .sol: host = "solscan.io/tx"
    case .eth: host = "etherscan.io/tx"
    case .base: host = "basescan.org/tx"
    case .bsc: host = "bscscan.com/tx"
    case .robinhood: return nil
    }
    return URL(string: "https://\(host)/\(hash)")
  }

  private static let percentOptions = [25, 50, 75, 100]
  private static let slippageOptions = [5, 8, 12, 20, 30]
}
