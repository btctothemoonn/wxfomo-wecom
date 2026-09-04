import SwiftUI
import WxFomoCore

private enum MemeCandidateMode: String, CaseIterable, Identifiable {
  case watchPool
  case crossGroup

  var id: String { rawValue }

  var title: String {
    switch self {
    case .watchPool: return "观察池"
    case .crossGroup: return "跨群信号"
    }
  }
}

private struct CAWatchPoolSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var model: AppModel
  @State private var draft = CAWatchPoolConfiguration()

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("CA 观察池设置", systemImage: "slider.horizontal.3")
          .font(.headline)
        Spacer()
        Toggle("启用", isOn: $draft.isEnabled)
          .toggleStyle(.switch)
      }
      .padding(16)

      Divider()

      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
        GridRow {
          Label("池容量", systemImage: "square.stack.3d.up")
          Stepper(value: $draft.capacity, in: 1...50) {
            Text("\(draft.capacity) 个")
              .monospacedDigit()
              .frame(width: 62, alignment: .leading)
          }
        }

        GridRow {
          Label("最低市值", systemImage: "chart.bar.xaxis.ascending")
          HStack(spacing: 6) {
            Text("$")
              .foregroundStyle(.secondary)
            TextField(
              "500000",
              value: $draft.minimumMarketCapUSD,
              format: .number.precision(.fractionLength(0))
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 118)
            Text("USD")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        GridRow {
          Label("刷新间隔", systemImage: "arrow.clockwise")
          Picker("刷新间隔", selection: $draft.refreshIntervalSeconds) {
            Text("1 分钟").tag(TimeInterval(60))
            Text("2 分钟").tag(TimeInterval(120))
            Text("5 分钟").tag(TimeInterval(300))
            Text("10 分钟").tag(TimeInterval(600))
            Text("30 分钟").tag(TimeInterval(1_800))
          }
          .labelsHidden()
          .frame(width: 140)
        }

        GridRow {
          Label("宽限次数", systemImage: "shield.lefthalf.filled")
          Stepper(value: $draft.graceAttemptCount, in: 1...10) {
            Text("\(draft.graceAttemptCount) 次")
              .monospacedDigit()
              .frame(width: 62, alignment: .leading)
          }
        }
      }
      .padding(16)

      Divider()

      HStack {
        Text("置顶 CA 不参与自动淘汰")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("取消") { dismiss() }
        Button {
          model.updateCAWatchPoolConfiguration(draft)
          dismiss()
        } label: {
          Label("应用", systemImage: "checkmark")
        }
        .buttonStyle(.borderedProminent)
      }
      .padding(14)
    }
    .frame(width: 390)
    .onAppear {
      draft = model.caWatchPoolConfiguration
    }
  }
}

struct MemeWorkspaceView: View {
  @EnvironmentObject private var model: AppModel
  @State private var candidateMode: MemeCandidateMode = .watchPool
  @State private var showsPoolSettings = false
  @State private var showsRemovedPool = false
  @State private var watchPoolPage = 1
  @State private var crossGroupPage = 1

  var body: some View {
    VStack(spacing: 0) {
      pageHeader
      Divider()
      HStack(spacing: 0) {
        candidatePane
          .frame(width: 310)
        Divider()
        reportPane
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onChange(of: candidateMode) { _, mode in
      if mode == .watchPool {
        watchPoolPage = 1
      } else {
        crossGroupPage = 1
      }
    }
  }

  private var pageHeader: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Meme 观察")
        .font(.title2.weight(.semibold))
      Text("跨群讨论 + 链上行情")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 18)
    .padding(.vertical, 11)
  }

  private var candidatePane: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text(candidateMode.title)
          .font(.headline)
        Spacer()
        Text(candidateCountLabel)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        if candidateMode == .watchPool {
          Button(action: model.refreshCAWatchPoolNow) {
            if model.isRefreshingCAWatchPool {
              ProgressView()
                .controlSize(.mini)
                .frame(width: 15, height: 15)
            } else {
              Image(systemName: "arrow.clockwise")
            }
          }
          .buttonStyle(.plain)
          .disabled(model.isRefreshingCAWatchPool || model.caWatchPoolItems.isEmpty)
          .help("立即刷新观察池行情")

          Button {
            showsPoolSettings.toggle()
          } label: {
            Image(systemName: "gearshape")
          }
          .buttonStyle(.plain)
          .help("观察池设置")
          .popover(isPresented: $showsPoolSettings, arrowEdge: .top) {
            CAWatchPoolSettingsView()
              .environmentObject(model)
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)

      Picker("候选来源", selection: $candidateMode) {
        ForEach(MemeCandidateMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .padding(.horizontal, 14)
      .padding(.bottom, 6)

      if candidateMode == .watchPool {
        watchPoolStatusBar
      }

      Divider()

      if candidateMode == .watchPool {
        watchPoolContent
      } else {
        if candidateIncidents.isEmpty {
          ContentUnavailableView {
            Label("还没有跨群地址", systemImage: "point.3.connected.trianglepath.dotted")
          } description: {
            Text("可在右侧手动输入地址查询。")
          }
        } else {
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(pagedCandidateIncidents) { incident in
                HStack(spacing: 0) {
                  Button {
                    model.openMemeMode(for: incident)
                  } label: {
                    candidateRow(incident)
                  }
                  .buttonStyle(.plain)
                  Button {
                    model.presentManualBuy(for: incident)
                  } label: {
                    Image(systemName: "bolt.horizontal.circle.fill")
                      .font(.title3)
                      .foregroundStyle(WxFomoTheme.priority)
                      .frame(width: 38, height: 38)
                  }
                  .buttonStyle(.plain)
                  .help("打开快速买入；点击立即买入后直接提交")
                  .padding(.trailing, 10)
                }
                Divider()
                  .padding(.leading, 16)
              }
            }
          }
          PaginationBar(totalCount: candidateIncidents.count, currentPage: $crossGroupPage)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  @ViewBuilder
  private var watchPoolContent: some View {
    if model.caWatchPoolItems.isEmpty {
      ContentUnavailableView {
        Label("观察池等待 CA", systemImage: "dot.radiowaves.left.and.right")
      } description: {
        Text("新消息中的地址会自动识别币名和市值。")
      }
    } else {
      ScrollView {
        LazyVStack(spacing: 0) {
          if let error = model.caWatchPoolError {
            Label(error, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
              .padding(12)
              .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
          }

          ForEach(pagedWatchPoolItems) { item in
            HStack(spacing: 0) {
              Button {
                model.openMemeMode(for: item)
              } label: {
                watchPoolRow(item)
              }
              .buttonStyle(.plain)
              Button {
                model.presentManualBuy(for: item)
              } label: {
                Image(systemName: "bolt.horizontal.circle.fill")
                  .font(.title3)
                  .foregroundStyle(WxFomoTheme.priority)
                  .frame(width: 38, height: 38)
              }
              .buttonStyle(.plain)
              .help("打开快速买入；点击立即买入后直接提交")
              .padding(.trailing, 10)
            }
            .frame(height: 48)
            .contextMenu {
              Button(item.isPinned ? "取消置顶" : "置顶") {
                model.toggleCAWatchPoolPin(item)
              }
              Button("查看市值详情") {
                model.openMemeMode(for: item)
              }
              Button("快速买入") {
                model.presentManualBuy(for: item)
              }
              Button("立即刷新") {
                model.refreshCAWatchPoolNow()
              }
              Divider()
              Button("移出观察池", role: .destructive) {
                model.removeCAWatchPoolItem(item)
              }
            }
            Divider()
              .padding(.leading, 16)
          }

          if !model.removedCAWatchPoolItems.isEmpty {
            DisclosureGroup(isExpanded: $showsRemovedPool) {
              ForEach(model.removedCAWatchPoolItems.prefix(8)) { item in
                removedPoolRow(item)
                Divider()
                  .padding(.leading, 16)
              }
            } label: {
              HStack(spacing: 6) {
                Label("最近移出", systemImage: "archivebox")
                  .font(.caption.weight(.semibold))
                Spacer()
                Text("\(model.removedCAWatchPoolItems.count)")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
          }
        }
      }
      if sortedWatchPoolItems.count > WorkspacePagination.pageSize {
        PaginationBar(totalCount: sortedWatchPoolItems.count, currentPage: $watchPoolPage)
      }
    }
  }

  private var watchPoolStatusBar: some View {
    HStack(spacing: 6) {
      Image(systemName: model.isRefreshingCAWatchPool
        ? "arrow.triangle.2.circlepath"
        : (model.caWatchPoolConfiguration.isEnabled ? "dot.radiowaves.left.and.right" : "pause.circle"))
        .foregroundStyle(model.isRefreshingCAWatchPool ? WxFomoTheme.signal : .secondary)
      Text(model.isRefreshingCAWatchPool ? "正在刷新" : (model.caWatchPoolConfiguration.isEnabled ? "后台监控" : "已暂停"))
        .lineLimit(1)
      Text("· 每 \(watchPoolRefreshTitle)")
        .foregroundStyle(.tertiary)
        .lineLimit(1)
      Spacer(minLength: 3)
      if model.caWatchPoolLastRefreshAt != nil {
        Text("本轮 \(model.caWatchPoolLastRefreshSucceededCount)/\(model.caWatchPoolLastRefreshSucceededCount + model.caWatchPoolLastRefreshFailedCount)")
          .monospacedDigit()
          .foregroundStyle(model.caWatchPoolLastRefreshFailedCount > 0 ? .orange : .secondary)
          .lineLimit(1)
      }
      if let next = model.caWatchPoolNextRefreshAt, model.caWatchPoolConfiguration.isEnabled {
        Text(next, style: .relative)
          .monospacedDigit()
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 14)
    .padding(.bottom, 6)
    .help("应用运行期间自动维护观察池市值；数据来自 DexScreener，失败时回退 GMGN")
  }

  private var candidateCountLabel: String {
    switch candidateMode {
    case .watchPool:
      return "\(model.caWatchPoolItems.count) / \(model.caWatchPoolConfiguration.capacity)"
    case .crossGroup:
      return "最近 \(candidateIncidents.count) 个"
    }
  }

  private var watchPoolRefreshTitle: String {
    let seconds = model.caWatchPoolConfiguration.refreshIntervalSeconds
    if seconds >= 3_600 {
      return "\(Int(seconds / 3_600)) 小时"
    }
    if seconds >= 60 {
      return "\(Int(seconds / 60)) 分钟"
    }
    return "\(Int(seconds)) 秒"
  }

  private var sortedWatchPoolItems: [CAWatchPoolItem] {
    model.caWatchPoolItems.sorted {
      if $0.isPinned != $1.isPinned { return $0.isPinned }
      return $0.latestSeenAt > $1.latestSeenAt
    }
  }

  private var pagedWatchPoolItems: [CAWatchPoolItem] {
    sortedWatchPoolItems.pageItems(page: watchPoolPage)
  }

  private var pagedCandidateIncidents: [CrossGroupAddressIncident] {
    candidateIncidents.pageItems(page: crossGroupPage)
  }

  private func watchPoolRow(_ item: CAWatchPoolItem) -> some View {
    let snapshot = item.currentSnapshot ?? item.entrySnapshot

    return HStack(alignment: .top, spacing: 8) {
      if let snapshot {
        TokenArtworkView(snapshot: snapshot, size: 30, cornerRadius: 6)
      } else {
        ZStack {
          RoundedRectangle(cornerRadius: 6)
            .fill(poolStateColor(item).opacity(0.12))
          Image(systemName: "hourglass")
            .foregroundStyle(poolStateColor(item))
        }
        .frame(width: 30, height: 30)
      }

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 5) {
          Text(poolTokenTitle(item))
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .layoutPriority(1)
          if let chain = item.chain ?? snapshot?.chain {
            TokenChainBadge(chain: chain, compact: true)
              .fixedSize(horizontal: true, vertical: false)
          }
          if item.isPinned {
            Image(systemName: "pin.fill")
              .font(.caption2)
              .foregroundStyle(.orange)
          }
          Spacer(minLength: 3)
          Text(formattedUSD(item.currentSnapshot?.marketCapUSD))
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(poolStateColor(item))
            .frame(minWidth: 56, alignment: .trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        HStack(spacing: 5) {
          Text(shortAddress(item.normalizedAddress))
            .font(.caption2.monospaced())
            .frame(width: 82, alignment: .leading)
            .lineLimit(1)
          Text("Liq \(formattedUSD(snapshot?.liquidityUSD))")
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
          Text("\(item.groupNames.count) 群 / \(item.mentionCount) 次")
            .frame(minWidth: 58, alignment: .trailing)
            .lineLimit(1)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .minimumScaleFactor(0.75)
      }
      Image(systemName: "chevron.right")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.top, 7)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: 48, alignment: .center)
    .contentShape(Rectangle())
  }

  private func removedPoolRow(_ item: CAWatchPoolItem) -> some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(poolTokenTitle(item))
          .font(.caption.weight(.medium))
          .lineLimit(1)
        Text(item.removalReason ?? "已移出")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      Button {
        model.restoreCAWatchPoolItem(item)
      } label: {
        Image(systemName: "arrow.uturn.backward")
      }
      .buttonStyle(.borderless)
      .help("恢复到观察池")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }

  private func poolTokenTitle(_ item: CAWatchPoolItem) -> String {
    let snapshot = item.currentSnapshot ?? item.entrySnapshot
    guard let snapshot else { return "正在识别" }
    if !snapshot.symbol.isEmpty, !snapshot.name.isEmpty,
      snapshot.symbol.caseInsensitiveCompare(snapshot.name) != .orderedSame
    {
      return "\(snapshot.symbol) · \(snapshot.name)"
    }
    return snapshot.symbol.isEmpty ? (snapshot.name.isEmpty ? "未知代币" : snapshot.name) : snapshot.symbol
  }

  private func shortAddress(_ address: String) -> String {
    guard address.count > 12 else { return address }
    return "\(address.prefix(6))...\(address.suffix(4))"
  }

  private func poolStateColor(_ item: CAWatchPoolItem) -> Color {
    guard let marketCap = item.currentSnapshot?.marketCapUSD else { return .secondary }
    return marketCap >= model.caWatchPoolConfiguration.minimumMarketCapUSD
      ? WxFomoTheme.signal : .orange
  }

  private func candidateRow(_ incident: CrossGroupAddressIncident) -> some View {
    let tokenSnapshot = model.caTokenSnapshot(for: incident)
    let triggerSnapshot = model.caTriggerSnapshot(for: incident)

    return VStack(alignment: .leading, spacing: 6) {
      Text(candidateTokenTitle(incident))
        .font(.callout.weight(.semibold))
        .lineLimit(1)
      Text(incident.normalizedAddress)
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      HStack(spacing: 8) {
        Text(tokenSnapshot?.chain.localizedTitle
          ?? (incident.family == .solana ? "Solana" : "待识别"))
        Text("\(incident.groupCount) 群")
        Text("\(incident.mentionCount) 次")
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      HStack(spacing: 6) {
        Image(systemName: "chart.bar.xaxis")
        Text(triggerSnapshot.map { "提示 \(formattedUSD($0.marketCapUSD))" } ?? "提示待识别")
          .fontWeight(.semibold)
        if let triggerSnapshot {
          Text("· \(triggerSnapshot.source.localizedTitle)")
            .foregroundStyle(.secondary)
        }
      }
      .font(.caption.monospacedDigit())
      .foregroundStyle(triggerSnapshot?.marketCapUSD == nil ? .secondary : WxFomoTheme.signal)
      .lineLimit(1)
      .help("跨群提醒产生时的市值快照，不是当前价")
      if let triggerSnapshot {
        Text("提示 \(triggerSnapshot.capturedAt.formatted(date: .omitted, time: .shortened))")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 4) {
        WxFomoTimePair(title: "首次", date: incident.firstSeenAt)
        WxFomoTimePair(title: "最近", date: incident.latestSeenAt)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
    .padding(.vertical, 11)
    .background(isSelected(incident) ? Color.accentColor.opacity(0.1) : Color.clear)
    .contentShape(Rectangle())
  }

  private func candidateTokenTitle(_ incident: CrossGroupAddressIncident) -> String {
    guard let snapshot = model.caTokenSnapshot(for: incident) else { return "CA 待识别" }
    if !snapshot.symbol.isEmpty, !snapshot.name.isEmpty,
      snapshot.symbol.caseInsensitiveCompare(snapshot.name) != .orderedSame
    {
      return "\(snapshot.symbol) · \(snapshot.name)"
    }
    if !snapshot.symbol.isEmpty { return snapshot.symbol }
    if !snapshot.name.isEmpty { return snapshot.name }
    return "未知代币"
  }

  private var reportPane: some View {
    VStack(spacing: 0) {
      queryToolbar
      if let message = model.memeChainDetectionMessage,
        !model.memeAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        chainDetectionStatus(message)
      }
      Divider()
      Group {
        if let error = model.memeQueryError {
          VStack(spacing: 0) {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.red)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 22)
              .padding(.vertical, 9)
            Divider()
            reportContent
          }
        } else {
          reportContent
        }
      }
    }
  }

  private var queryToolbar: some View {
    HStack(spacing: 10) {
      TextField("输入完整代币地址", text: $model.memeAddressDraft)
        .textFieldStyle(.roundedBorder)
        .font(.body.monospaced())
        .onSubmit(model.queryMemeToken)
        .onChange(of: model.memeAddressDraft) {
          model.handleMemeAddressChange(model.memeAddressDraft)
        }

      Picker(
        "网络",
        selection: Binding(
          get: { model.memeSelectedChain },
          set: { model.selectMemeChain($0) }
        )
      ) {
        Text("自动识别").tag(Optional<GMGNChain>.none)
        ForEach(GMGNChain.allCases) { chain in
          Text(chain.localizedTitle).tag(Optional(chain))
        }
      }
      .frame(width: 130)

      Button(action: model.queryMemeToken) {
        if model.isQueryingMeme || model.isDetectingMemeChain {
          ProgressView()
            .controlSize(.small)
            .frame(width: 18, height: 18)
        } else {
          Label("查询", systemImage: "magnifyingglass")
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(
        model.isQueryingMeme
          || model.isDetectingMemeChain
          || model.memeAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      )
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 11)
  }

  @ViewBuilder
  private var reportContent: some View {
    if model.isQueryingMeme, model.memeTokenReport == nil {
      VStack(spacing: 12) {
        ProgressView()
          .controlSize(.regular)
        Text("正在获取币种详情")
          .font(.headline)
        Text("优先读取 GMGN；不可用时回退到 DexScreener 基础行情")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let report = model.memeTokenReport {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          identitySection(report)
          Divider()
          localDiscussionSection
          Divider()
          marketSection(report.token)
          Divider()
          securitySection(report)
          Divider()
          provenanceSection(report)
        }
      }
    } else if model.isDetectingMemeChain {
      ContentUnavailableView {
        Label("正在识别网络", systemImage: "network")
      } description: {
        Text("正在读取 DexScreener 交易对与主流动性。")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if !model.memeChainCandidates.isEmpty,
      model.memeSelectedChain == nil
    {
      ambiguousChainCandidates
    } else if !model.memeAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      model.memeSelectedChain == nil
    {
      ContentUnavailableView {
        Label("未识别到唯一网络", systemImage: "point.3.filled.connected.trianglepath.dotted")
      } description: {
        Text("DexScreener 没有唯一结果，可从网络菜单手动选择。")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ContentUnavailableView {
        Label("等待查询", systemImage: "chart.xyaxis.line")
      } description: {
        Text("选择左侧跨群候选，或输入地址与网络。")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func chainDetectionStatus(_ message: String) -> some View {
    HStack(spacing: 7) {
      if model.isDetectingMemeChain {
        ProgressView()
          .controlSize(.small)
      } else {
        Image(systemName: model.memeSelectedChain == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
          .foregroundStyle(model.memeSelectedChain == nil ? Color.orange : WxFomoTheme.signal)
      }
      Text(message)
        .lineLimit(1)
      Spacer()
      Text("DexScreener")
        .foregroundStyle(.tertiary)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 22)
    .padding(.bottom, 8)
  }

  private var ambiguousChainCandidates: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("同一地址命中多个网络", systemImage: "point.3.connected.trianglepath.dotted")
        .font(.headline)
      Text("主流动性接近，自动选择可能混用不同链上的资产。请选择要查询的网络。")
        .font(.callout)
        .foregroundStyle(.secondary)

      ForEach(model.memeChainCandidates) { candidate in
        Button {
          model.selectMemeChain(candidate.chain)
          model.queryMemeToken()
        } label: {
          HStack(spacing: 12) {
            metricIcon("link.circle.fill", tint: chainColor(candidate.chain), size: 34)
            VStack(alignment: .leading, spacing: 3) {
              Text(candidate.chain.localizedTitle)
                .font(.callout.weight(.semibold))
              Text("\(candidate.pairCount) 个交易对 · 主池流动性 \(formattedUSD(candidate.maxLiquidityUSD)) · 24h 成交 \(formattedUSD(candidate.maxVolume24hUSD))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
              .foregroundStyle(.tertiary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Divider()
      }
    }
    .frame(maxWidth: 620, maxHeight: .infinity, alignment: .topLeading)
    .padding(28)
  }

  private func identitySection(_ report: GMGNTokenReport) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 14) {
        tokenLogo(report.token)

        VStack(alignment: .leading, spacing: 7) {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(report.token.symbol.isEmpty ? "未知代币" : report.token.symbol)
              .font(.title3.weight(.semibold))
            if !report.token.name.isEmpty {
              Text(report.token.name)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Button {
              model.presentManualBuy(for: report)
            } label: {
              Label("快速买入", systemImage: "bolt.horizontal.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(WxFomoTheme.priority)
            .help("打开快速买入；点击立即买入后直接提交")
            Label(report.token.chain.localizedTitle, systemImage: "link.circle.fill")
              .font(.caption.weight(.medium))
              .foregroundStyle(chainColor(report.token.chain))
          }
          Text(report.token.address)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }

      HStack(spacing: 10) {
        if let website = safeURL(report.token.website) {
          Link(destination: website) {
            Label("网站", systemImage: "globe")
          }
        }
        if let username = report.token.twitterUsername,
          let twitter = safeURL("https://x.com/\(username)")
        {
          Link(destination: twitter) {
            Label("X", systemImage: "at")
          }
        }
      }
      .font(.caption)

      VStack(alignment: .leading, spacing: 8) {
        Label("外部行情", systemImage: "arrow.up.right.square")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            if let gmgn = safeURL(report.token.gmgnURL) {
              externalLink("GMGN", systemImage: "waveform.path.ecg", destination: gmgn)
            }
            if let fomo = fomoURL(for: report.token) {
              externalLink("Fomo", systemImage: "bolt.fill", destination: fomo)
            }
            if let gecko = safeURL(report.token.geckoTerminalURL) {
              externalLink("GeckoTerminal", systemImage: "chart.xyaxis.line", destination: gecko)
            }
            if let dexScreener = dexScreenerURL(for: report.token) {
              externalLink("DexScreener", systemImage: "chart.bar.xaxis", destination: dexScreener)
            }
          }
        }
      }
    }
    .padding(22)
  }

  private var localDiscussionSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("群聊热度", systemImage: "person.3.sequence.fill")
          .font(.headline)
        Spacer()
        Text("近 24 小时")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if model.isLoadingMemeMentionSummary {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("正在汇总本机群聊提及")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
      } else if let summary = model.memeMentionSummary {
        HStack(alignment: .top, spacing: 0) {
          headlineMetric(
            "提及群数",
            "\(summary.groupCount) 个",
            systemImage: "person.3.fill",
            tint: .blue
          )
          Divider()
            .frame(height: 50)
            .padding(.horizontal, 18)
          headlineMetric(
            "提及次数",
            "\(summary.mentionCount) 次",
            systemImage: "bubble.left.and.bubble.right.fill",
            tint: .orange
          )
          Divider()
            .frame(height: 50)
            .padding(.horizontal, 18)
          headlineMetric(
            "最近提及",
            summary.latestSeenAt.formatted(date: .omitted, time: .shortened),
            systemImage: "clock.fill",
            tint: WxFomoTheme.signal
          )
        }

        Text(summary.groupNames.map(model.displayGroupName).joined(separator: " · "))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .textSelection(.enabled)
      } else if let error = model.memeMentionSummaryError {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.callout)
          .foregroundStyle(.orange)
      } else {
        Label("近 24 小时没有本机采集到该地址的群聊提及", systemImage: "person.3")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .padding(22)
    .background(Color.accentColor.opacity(0.035))
  }

  private func marketSection(_ token: GMGNTokenSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("市场快照", systemImage: "chart.line.uptrend.xyaxis")
        .font(.headline)
        .foregroundStyle(.primary)

      HStack(alignment: .top, spacing: 0) {
        headlineMetric(
          "价格",
          formattedPrice(token.priceUSD),
          systemImage: "dollarsign.circle.fill",
          tint: .blue
        )
        Divider()
          .frame(height: 50)
          .padding(.horizontal, 18)
        headlineMetric(
          "估算流通市值",
          formattedUSD(token.marketCapUSD),
          systemImage: "chart.bar.xaxis.ascending",
          tint: WxFomoTheme.signal
        )
        Divider()
          .frame(height: 50)
          .padding(.horizontal, 18)
        headlineMetric(
          "流动性",
          formattedUSD(token.liquidityUSD),
          systemImage: "drop.fill",
          tint: .orange
        )
      }

      Divider()

      Grid(alignment: .leading, horizontalSpacing: 26, verticalSpacing: 10) {
        GridRow {
          metric(
            "1 小时成交额",
            formattedUSD(token.volume1hUSD),
            systemImage: "waveform.path.ecg",
            tint: .indigo
          )
          metric(
            "1 小时变化",
            formattedPercent(token.priceChange1hPercent),
            systemImage: changeIcon(token.priceChange1hPercent),
            tint: changeColor(token.priceChange1hPercent)
          )
          metric(
            "持有人",
            formattedCount(token.holderCount),
            systemImage: "person.2.fill",
            tint: .blue
          )
        }
        GridRow {
          metric(
            "聪明钱钱包",
            formattedCount(token.smartWalletCount),
            systemImage: "brain.head.profile",
            tint: .orange
          )
          metric(
            "KOL 钱包",
            formattedCount(token.renownedWalletCount),
            systemImage: "megaphone.fill",
            tint: .pink
          )
          Color.clear.frame(height: 1)
        }
      }
    }
    .padding(22)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.22))
  }

  private func securitySection(_ report: GMGNTokenReport) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("安全字段", systemImage: "checkmark.shield.fill")
        .font(.headline)
        .foregroundStyle(.primary)
      if let security = report.security {
        if security.isHoneypot?.lowercased() == "yes" {
          Label("GMGN 返回 honeypot=yes", systemImage: "exclamationmark.octagon.fill")
            .foregroundStyle(.red)
            .font(.callout.weight(.semibold))
        }
        Grid(alignment: .leading, horizontalSpacing: 26, verticalSpacing: 10) {
          GridRow {
            metric("合约开源", security.openSource ?? "未返回", systemImage: "chevron.left.forwardslash.chevron.right", tint: .blue)
            metric("权限放弃", security.ownerRenounced ?? "未返回", systemImage: "lock.open.fill", tint: WxFomoTheme.signal)
            metric("蜜罐", security.isHoneypot ?? "不适用或未返回", systemImage: "exclamationmark.hexagon.fill", tint: .red)
          }
          GridRow {
            metric("Rug 比例", formattedRatio(security.rugRatio), systemImage: "shield.lefthalf.filled", tint: .orange)
            metric("前十持仓", formattedRatio(security.top10HolderRate), systemImage: "chart.pie.fill", tint: .indigo)
            metric("开发团队持仓", formattedRatio(security.devTeamHoldRate), systemImage: "hammer.fill", tint: .purple)
          }
          GridRow {
            metric("疑似内部持仓", formattedRatio(security.suspectedInsiderHoldRate), systemImage: "eye.trianglebadge.exclamationmark", tint: .orange)
            metric("刷量", formattedBoolean(security.washTrading), systemImage: "arrow.triangle.2.circlepath", tint: .red)
            metric("买入 / 卖出税", formattedTaxes(security), systemImage: "percent", tint: .blue)
          }
          if report.token.chain == .sol {
            GridRow {
              metric("Mint 权限放弃", formattedBoolean(security.mintRenounced), systemImage: "banknote.fill", tint: WxFomoTheme.signal)
              metric("Freeze 权限放弃", formattedBoolean(security.freezeRenounced), systemImage: "snowflake", tint: .cyan)
              Color.clear.frame(height: 1)
            }
          }
        }
      } else {
        Label(
          report.securityError ?? "安全数据未返回，待核验。",
          systemImage: "exclamationmark.shield"
        )
        .font(.callout)
        .foregroundStyle(.orange)
      }
    }
    .padding(22)
  }

  private func provenanceSection(_ report: GMGNTokenReport) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Label("数据边界", systemImage: "info.circle.fill")
        .font(.headline)
        .foregroundStyle(.primary)
      Text("群聊统计仅基于本机已采集通知，不代表微信群完整消息流。\(report.marketDataSource.localizedTitle) 行情是 \(report.fetchedAt.formatted(date: .abbreviated, time: .standard)) 的外部快照，不构成代币身份保证或投资建议。")
        .font(.caption)
        .foregroundStyle(.secondary)
      if report.isCached {
        Text("本次显示来自 45 秒本地缓存。")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(22)
  }

  private func metric(
    _ title: String,
    _ value: String,
    systemImage: String,
    tint: Color
  ) -> some View {
    HStack(alignment: .top, spacing: 8) {
      metricIcon(systemImage, tint: tint, size: 25)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.callout.monospacedDigit().weight(.medium))
          .textSelection(.enabled)
          .lineLimit(1)
          .minimumScaleFactor(0.78)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func headlineMetric(
    _ title: String,
    _ value: String,
    systemImage: String,
    tint: Color
  ) -> some View {
    HStack(spacing: 10) {
      metricIcon(systemImage, tint: tint, size: 34)
      VStack(alignment: .leading, spacing: 5) {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.title3.monospacedDigit().weight(.semibold))
          .textSelection(.enabled)
          .lineLimit(1)
          .minimumScaleFactor(0.72)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func metricIcon(_ systemImage: String, tint: Color, size: CGFloat) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 6)
        .fill(tint.opacity(0.14))
      Image(systemName: systemImage)
        .font(.system(size: size * 0.46, weight: .semibold))
        .foregroundStyle(tint)
    }
    .frame(width: size, height: size)
  }

  @ViewBuilder
  private func tokenLogo(_ token: GMGNTokenSnapshot) -> some View {
    if let logoURL = safeImageURL(token.logoURL) {
      Link(destination: logoURL) {
        AsyncImage(url: logoURL, transaction: Transaction(animation: .easeOut(duration: 0.18))) { phase in
          switch phase {
          case .success(let image):
            image
              .resizable()
              .scaledToFill()
              .transition(.opacity)
          case .empty:
            ZStack {
              tokenLogoPlaceholder
              ProgressView()
                .controlSize(.small)
            }
          case .failure:
            tokenLogoPlaceholder
          @unknown default:
            tokenLogoPlaceholder
          }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
      }
      .buttonStyle(.plain)
      .help("在浏览器打开代币图片")
      .accessibilityLabel("代币图片")
    } else {
      tokenLogoPlaceholder
        .frame(width: 64, height: 64)
    }
  }

  private var tokenLogoPlaceholder: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8)
        .fill(WxFomoTheme.signal.opacity(0.13))
      Image(systemName: "photo.badge.exclamationmark")
        .font(.system(size: 23, weight: .semibold))
        .foregroundStyle(WxFomoTheme.signal)
    }
  }

  private func externalLink(
    _ title: String,
    systemImage: String,
    destination: URL
  ) -> some View {
    Link(destination: destination) {
      Label(title, systemImage: systemImage)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .help("在浏览器打开 \(title)")
  }

  private func fomoURL(for token: GMGNTokenSnapshot) -> URL? {
    let slug: String
    switch token.chain {
    case .sol: slug = "solana"
    case .eth: slug = "ethereum"
    case .base: slug = "base"
    case .bsc: slug = "bnb"
    case .robinhood: slug = "robinhood"
    }
    return platformURL(
      host: "fomo.family",
      pathComponents: ["tokens", slug, token.address]
    )
  }

  private func dexScreenerURL(for token: GMGNTokenSnapshot) -> URL? {
    let slug: String
    switch token.chain {
    case .sol: slug = "solana"
    case .eth: slug = "ethereum"
    case .base: slug = "base"
    case .bsc: slug = "bsc"
    case .robinhood: slug = "robinhood"
    }
    return platformURL(
      host: "dexscreener.com",
      pathComponents: [slug, token.address]
    )
  }

  private func platformURL(host: String, pathComponents: [String]) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.path = "/" + pathComponents.joined(separator: "/")
    return components.url
  }

  private func chainColor(_ chain: GMGNChain) -> Color {
    switch chain {
    case .sol: return .purple
    case .eth: return .blue
    case .base: return .indigo
    case .bsc: return .orange
    case .robinhood: return WxFomoTheme.signal
    }
  }

  private func changeColor(_ value: Double?) -> Color {
    guard let value, value.isFinite else { return .secondary }
    return value >= 0 ? WxFomoTheme.signal : WxFomoTheme.priority
  }

  private func changeIcon(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "minus" }
    return value >= 0 ? "arrow.up.right" : "arrow.down.right"
  }

  private var candidateIncidents: [CrossGroupAddressIncident] {
    var seen = Set<String>()
    return model.crossGroupAddressIncidents.filter { incident in
      seen.insert("\(incident.family.rawValue):\(incident.normalizedAddress)").inserted
    }
  }

  private func isSelected(_ incident: CrossGroupAddressIncident) -> Bool {
    model.memeAddressDraft == incident.normalizedAddress
  }

  private func safeURL(_ value: String?) -> URL? {
    guard let value, let url = URL(string: value),
      url.scheme == "https"
    else { return nil }
    return url
  }

  private func safeImageURL(_ value: String?) -> URL? {
    guard let url = safeURL(value), url.host != nil else { return nil }
    return url
  }

  private func formattedPrice(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "未返回" }
    if value == 0 { return "$0" }
    if abs(value) >= 1 { return value.formatted(.currency(code: "USD").precision(.fractionLength(2...6))) }
    return "$" + value.formatted(.number.precision(.significantDigits(2...6)))
  }

  private func formattedUSD(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "未返回" }
    let magnitude = abs(value)
    if magnitude >= 1_000_000_000 {
      return "$" + (value / 1_000_000_000).formatted(.number.precision(.fractionLength(1...2))) + "B"
    }
    if magnitude >= 1_000_000 {
      return "$" + (value / 1_000_000).formatted(.number.precision(.fractionLength(1...2))) + "M"
    }
    if magnitude >= 1_000 {
      return "$" + (value / 1_000).formatted(.number.precision(.fractionLength(1...2))) + "K"
    }
    return value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
  }

  private func formattedPercent(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "未返回" }
    let prefix = value > 0 ? "+" : ""
    return prefix + value.formatted(.number.precision(.fractionLength(2))) + "%"
  }

  private func formattedRatio(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "未返回" }
    return (value * 100).formatted(.number.precision(.fractionLength(2))) + "%"
  }

  private func formattedCount(_ value: Int?) -> String {
    value?.formatted() ?? "未返回"
  }

  private func formattedBoolean(_ value: Bool?) -> String {
    guard let value else { return "未返回" }
    return value ? "是" : "否"
  }

  private func formattedTaxes(_ security: GMGNTokenSecuritySnapshot) -> String {
    guard security.buyTax != nil || security.sellTax != nil else { return "未返回" }
    return "\(formattedRatio(security.buyTax)) / \(formattedRatio(security.sellTax))"
  }
}
