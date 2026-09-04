import AppKit
import SwiftUI
import WxFomoCore

struct MarketTrendWorkspaceView: View {
  @EnvironmentObject private var model: AppModel
  @State private var selectedChain: GMGNChain = .sol
  @State private var selectedOrderBy: GMGNMarketOrderBy = .default
  @State private var selectedDirection: GMGNMarketDirection = .descending
  @State private var selectedToken: GMGNTrendingToken?

  private var requestKey: String {
    "\(selectedChain.rawValue):\(selectedOrderBy.rawValue):\(selectedDirection.rawValue)"
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .sheet(item: $selectedToken) { token in
      MarketTrendTokenDetailView(token: token)
        .environmentObject(model)
    }
    .task(id: requestKey) {
      while !Task.isCancelled {
        model.refreshMarketTrends(
          chain: selectedChain,
          interval: .oneHour,
          orderBy: selectedOrderBy,
          direction: selectedDirection
        )
        do {
          try await Task.sleep(for: .seconds(120))
        } catch {
          return
        }
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text("市场趋势")
            .font(.title2.weight(.semibold))
          Text("GMGN 多链热门榜 · 按 \(selectedOrderBy.title) · 自动刷新")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let lastRefresh = model.marketTrendingLastRefreshAt {
          Label(
            "更新于 \(lastRefresh.formatted(date: .omitted, time: .shortened))",
            systemImage: "clock"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Button {
          model.refreshMarketTrends(
            chain: selectedChain,
            interval: .oneHour,
            orderBy: selectedOrderBy,
            direction: selectedDirection,
            forceRefresh: true
          )
        } label: {
          if model.isLoadingMarketTrends {
            ProgressView()
              .controlSize(.small)
              .frame(width: 16, height: 16)
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .buttonStyle(.bordered)
        .help("立即刷新当前榜单")
        .disabled(model.isLoadingMarketTrends)
      }

      HStack(spacing: 10) {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(GMGNChain.allCases) { chain in
              Button {
                selectedChain = chain
              } label: {
                Label(chain.localizedTitle, systemImage: chainSymbol(chain))
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(
                    selectedChain == chain ? TokenChainBadge.color(for: chain) : .secondary
                  )
                  .padding(.horizontal, 10)
                  .padding(.vertical, 6)
                  .background(
                    selectedChain == chain
                      ? TokenChainBadge.color(for: chain).opacity(0.14)
                      : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                  )
                  .overlay {
                    if selectedChain == chain {
                      RoundedRectangle(cornerRadius: 6)
                        .stroke(TokenChainBadge.color(for: chain).opacity(0.45), lineWidth: 1)
                    }
                  }
              }
              .buttonStyle(.plain)
              .help("查看 \(chain.localizedTitle) 1h 热门前 10")
            }
          }
        }

        Label(
          "1h · \(selectedOrderBy.title) · \(selectedDirection.title)",
          systemImage: selectedOrderBy == .default ? "flame.fill" : "arrow.up.arrow.down"
        )
          .font(.caption.weight(.semibold))
          .foregroundStyle(WxFomoTheme.signal)
        Spacer()
      }

      HStack(spacing: 8) {
        Label("排序", systemImage: "arrow.up.arrow.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(sortOrderings) { orderBy in
              Button {
                selectedOrderBy = orderBy
              } label: {
                Text(orderBy.title)
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(selectedOrderBy == orderBy ? WxFomoTheme.signal : .secondary)
                  .padding(.horizontal, 9)
                  .padding(.vertical, 5)
                  .background(
                    selectedOrderBy == orderBy
                      ? WxFomoTheme.signal.opacity(0.14)
                      : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                  )
                  .overlay {
                    if selectedOrderBy == orderBy {
                      RoundedRectangle(cornerRadius: 6)
                        .stroke(WxFomoTheme.signal.opacity(0.45), lineWidth: 1)
                    }
                  }
              }
              .buttonStyle(.plain)
              .help("按 \(orderBy.title) 排序")
            }
          }
        }
        Button {
          selectedDirection.toggle()
        } label: {
          Label(selectedDirection.title, systemImage: selectedDirection.symbol)
            .font(.caption.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("切换升序或降序")
        Spacer(minLength: 0)
      }
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 16)
  }

  @ViewBuilder
  private var content: some View {
    if let error = model.marketTrendingError, model.marketTrendingTokens.isEmpty {
      ContentUnavailableView {
        Label("榜单暂时不可用", systemImage: "wifi.exclamationmark")
      } description: {
        Text(error)
      } actions: {
        Button("重试") {
          model.refreshMarketTrends(
            chain: selectedChain,
            interval: .oneHour,
            orderBy: selectedOrderBy,
            direction: selectedDirection,
            forceRefresh: true
          )
        }
        .buttonStyle(.borderedProminent)
      }
    } else if model.marketTrendingTokens.isEmpty && model.isLoadingMarketTrends {
      VStack(spacing: 12) {
        ProgressView()
        Text("正在读取 \(selectedChain.localizedTitle) 榜单…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.marketTrendingTokens.isEmpty {
      ContentUnavailableView {
        Label("暂无趋势数据", systemImage: "chart.line.uptrend.xyaxis")
      } description: {
        Text("GMGN 当前没有返回可用的代币排行。")
      }
    } else {
      VStack(alignment: .leading, spacing: 0) {
        tableHeader
        Divider()
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(model.marketTrendingTokens) { token in
              trendRow(token)
              Divider().padding(.leading, 22)
            }
          }
        }
        if let error = model.marketTrendingError {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
        }
      }
      .padding(.top, 4)
    }
  }

  private var tableHeader: some View {
    HStack(spacing: 12) {
      Text("排名")
        .frame(width: 34, alignment: .leading)
      Text("代币")
      Spacer()
      Text(changeColumnTitle)
        .frame(width: 96, alignment: .trailing)
      Text("市值")
        .frame(width: 94, alignment: .trailing)
      Text("流动性")
        .frame(width: 94, alignment: .trailing)
      Text("成交量 / 笔数")
        .frame(width: 94, alignment: .trailing)
      Text("操作")
        .frame(width: 128, alignment: .trailing)
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 22)
    .padding(.vertical, 8)
  }

  private func trendRow(_ token: GMGNTrendingToken) -> some View {
    HStack(spacing: 12) {
      Text("#\(token.rank)")
        .font(.caption.monospacedDigit().weight(.semibold))
        .foregroundStyle(token.rank <= 3 ? WxFomoTheme.priority : .secondary)
        .frame(width: 34, alignment: .leading)

      TokenArtworkView(snapshot: tokenSnapshot(token), size: 36, cornerRadius: 8)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Text(token.symbol.isEmpty ? token.name : token.symbol)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
          TokenChainBadge(chain: token.chain, compact: true)
          if let platform = token.launchpadPlatform, !platform.isEmpty {
            Text(platform)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Text(token.name.isEmpty ? token.address : token.name)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(shortAddress(token.address))
          .font(.caption2.monospaced())
          .foregroundStyle(.tertiary)
      }
      .frame(minWidth: 180, alignment: .leading)

      Spacer(minLength: 8)

      VStack(alignment: .trailing, spacing: 3) {
        Text(formattedPercent(changeValue(for: token)))
          .font(.callout.monospacedDigit().weight(.bold))
          .foregroundStyle(changeColor(changeValue(for: token)))
        if let price = token.priceUSD {
          Text(formattedPrice(price))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      .frame(width: 96, alignment: .trailing)

      metricText(compactUSD(token.marketCapUSD), width: 94)
      metricText(compactUSD(token.liquidityUSD), width: 94)
      VStack(alignment: .trailing, spacing: 3) {
        metricText(compactUSD(token.volumeUSD), width: 94)
        if let swapCount = token.swapCount {
          Text("\(formattedCount(swapCount)) 笔")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      .frame(width: 94, alignment: .trailing)

      HStack(spacing: 5) {
        if let url = TokenExternalLinks.gmgn(chain: token.chain, address: token.address) {
          Link(destination: url) {
            Image(systemName: "chart.line.uptrend.xyaxis")
          }
          .help("在 GMGN 打开")
        }
        if let url = TokenExternalLinks.fomo(chain: token.chain, address: token.address) {
          Link(destination: url) {
            Image(systemName: "globe")
          }
          .help("在 Fomo 打开")
        }
        Button {
          model.openMemeMode(for: token)
        } label: {
          Image(systemName: "waveform.path.ecg.rectangle")
        }
        .buttonStyle(.borderless)
        .help("在 Meme 观察中查询")
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(token.address, forType: .string)
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("复制合约地址")
      }
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(width: 128, alignment: .trailing)
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 10)
    .contentShape(Rectangle())
    .onTapGesture {
      selectedToken = token
    }
    .contextMenu {
      Button("复制合约地址") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token.address, forType: .string)
      }
      Button("在 Meme 观察中查询") {
        model.openMemeMode(for: token)
      }
      if let url = TokenExternalLinks.gmgn(chain: token.chain, address: token.address) {
        Link("在 GMGN 打开", destination: url)
      }
      if let url = TokenExternalLinks.fomo(chain: token.chain, address: token.address) {
        Link("在 Fomo 打开", destination: url)
      }
    }
  }

  private func metricText(_ value: String, width: CGFloat) -> some View {
    Text(value)
      .font(.caption.monospacedDigit())
      .foregroundStyle(.primary)
      .frame(width: width, alignment: .trailing)
  }

  private func tokenSnapshot(_ token: GMGNTrendingToken) -> CATokenMarketSnapshot {
    CATokenMarketSnapshot(
      chain: token.chain,
      address: token.address,
      symbol: token.symbol,
      name: token.name,
      priceUSD: token.priceUSD,
      marketCapUSD: token.marketCapUSD,
      liquidityUSD: token.liquidityUSD,
      logoURL: token.logoURL,
      capturedAt: model.marketTrendingLastRefreshAt ?? Date(),
      source: .gmgn
    )
  }

  private func chainSymbol(_ chain: GMGNChain) -> String {
    switch chain {
    case .sol: return "line.3.horizontal"
    case .eth: return "diamond.fill"
    case .base: return "b.circle.fill"
    case .bsc: return "hexagon.fill"
    case .robinhood: return "leaf.fill"
    }
  }

  private var sortOrderings: [GMGNMarketOrderBy] {
    [
      .default,
      .marketCap,
      .volume,
      .swaps,
      .liquidity,
      .change1h,
      .change5m,
      .change1m,
      .holderCount,
      .smartDegenCount,
      .renownedCount,
      .creationTimestamp,
      .historyHighestMarketCap,
      .price,
      .gasFee,
    ]
  }

  private var changeColumnTitle: String {
    switch selectedOrderBy {
    case .change1m: return "1m 涨跌幅"
    case .change5m: return "5m 涨跌幅"
    default: return "1h 涨跌幅"
    }
  }

  private func changeValue(for token: GMGNTrendingToken) -> Double? {
    switch selectedOrderBy {
    case .change1m: return token.priceChange1mPercent
    case .change5m: return token.priceChange5mPercent
    default: return token.priceChangePercent
    }
  }

  private func shortAddress(_ address: String) -> String {
    guard address.count > 14 else { return address }
    return "\(address.prefix(7))…\(address.suffix(6))"
  }

  private func formattedPercent(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    let sign = value > 0 ? "+" : ""
    return sign + value.formatted(.number.precision(.fractionLength(1))) + "%"
  }

  private func formattedPrice(_ value: Double) -> String {
    guard value.isFinite else { return "—" }
    return "$" + value.formatted(.number.precision(.fractionLength(2...8)))
  }

  private func compactUSD(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    let absolute = abs(value)
    if absolute >= 1_000_000 {
      return "$" + (value / 1_000_000).formatted(.number.precision(.fractionLength(1...2))) + "M"
    }
    if absolute >= 1_000 {
      return "$" + (value / 1_000).formatted(.number.precision(.fractionLength(1...2))) + "K"
    }
    return value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
  }

  private func formattedCount(_ value: Int) -> String {
    value.formatted(.number.grouping(.automatic))
  }

  private func changeColor(_ value: Double?) -> Color {
    guard let value, value.isFinite else { return .secondary }
    return value >= 0 ? WxFomoTheme.signal : .red
  }
}

private struct MarketTrendTokenDetailView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let token: GMGNTrendingToken

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 12) {
        TokenArtworkView(snapshot: snapshot, size: 58, cornerRadius: 12)
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(token.symbol.isEmpty ? token.name : token.symbol)
              .font(.title3.weight(.bold))
              .lineLimit(1)
            TokenChainBadge(chain: token.chain)
          }
          Text(token.name.isEmpty ? "未命名代币" : token.name)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Text(token.address)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Spacer()
        Button { dismiss() } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("关闭详情")
      }
      .padding(20)

      Divider()

      Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 14) {
        GridRow {
          detailMetric("1h 涨跌幅", formattedPercent(token.priceChangePercent), color: changeColor)
          detailMetric("价格", formattedPrice(token.priceUSD), color: .primary)
        }
        GridRow {
          detailMetric("市值", compactUSD(token.marketCapUSD), color: .primary)
          detailMetric("流动性", compactUSD(token.liquidityUSD), color: .primary)
        }
        GridRow {
          detailMetric("1h 成交量", compactUSD(token.volumeUSD), color: .primary)
          detailMetric("交易笔数", token.swapCount.map { formattedCount($0) } ?? "—", color: .primary)
        }
        GridRow {
          detailMetric("持有人", token.holderCount.map(String.init) ?? "—", color: .primary)
          detailMetric("Smart Money", token.smartWalletCount.map(String.init) ?? "—", color: .primary)
        }
        GridRow {
          detailMetric("KOL", token.renownedWalletCount.map(String.init) ?? "—", color: .primary)
          detailMetric("榜单周期", token.interval.title, color: .secondary)
        }
      }
      .padding(20)

      if let rugRatio = token.rugRatio, rugRatio > 0.3 || token.isHoneypot == true {
        Label(
          token.isHoneypot == true ? "GMGN 标记为蜜罐风险" : "Rug 风险比率较高：\(rugRatio.formatted(.percent.precision(.fractionLength(0...1))))",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(.orange)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
      }

      Divider()

      HStack(spacing: 10) {
        if let url = TokenExternalLinks.gmgn(chain: token.chain, address: token.address) {
          Link(destination: url) {
            Label("GMGN", systemImage: "chart.line.uptrend.xyaxis")
          }
          .buttonStyle(.borderedProminent)
        }
        if let url = TokenExternalLinks.fomo(chain: token.chain, address: token.address) {
          Link(destination: url) {
            Label("Fomo", systemImage: "globe")
          }
          .buttonStyle(.bordered)
        }
        Button {
          model.openMemeMode(for: token)
          dismiss()
        } label: {
          Label("Meme 观察", systemImage: "waveform.path.ecg.rectangle")
        }
        .buttonStyle(.bordered)
        Spacer()
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(token.address, forType: .string)
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("复制合约地址")
      }
      .padding(16)
    }
    .frame(width: 540)
  }

  private var snapshot: CATokenMarketSnapshot {
    CATokenMarketSnapshot(
      chain: token.chain,
      address: token.address,
      symbol: token.symbol,
      name: token.name,
      priceUSD: token.priceUSD,
      marketCapUSD: token.marketCapUSD,
      liquidityUSD: token.liquidityUSD,
      logoURL: token.logoURL,
      capturedAt: Date(),
      source: .gmgn
    )
  }

  private var changeColor: Color {
    guard let value = token.priceChangePercent, value.isFinite else { return .secondary }
    return value >= 0 ? WxFomoTheme.signal : .red
  }

  private func detailMetric(_ title: String, _ value: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.body.monospacedDigit().weight(.semibold))
        .foregroundStyle(color)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func formattedPercent(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    let sign = value > 0 ? "+" : ""
    return sign + value.formatted(.number.precision(.fractionLength(1))) + "%"
  }

  private func formattedPrice(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return "$" + value.formatted(.number.precision(.fractionLength(2...8)))
  }

  private func compactUSD(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    let absolute = abs(value)
    if absolute >= 1_000_000 {
      return "$" + (value / 1_000_000).formatted(.number.precision(.fractionLength(1...2))) + "M"
    }
    if absolute >= 1_000 {
      return "$" + (value / 1_000).formatted(.number.precision(.fractionLength(1...2))) + "K"
    }
    return value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
  }

  private func formattedCount(_ value: Int) -> String {
    value.formatted(.number.grouping(.automatic))
  }
}
