import AppKit
import SwiftUI
import WxFomoCore

struct AlertsWorkspaceView: View {
  @EnvironmentObject private var model: AppModel
  @State private var filter: AlertListFilter = .unacknowledged
  @State private var currentPage = 1

  var body: some View {
    VStack(spacing: 0) {
      pageHeader
      Divider()
      toolbar
      Divider()
      content
    }
    .onAppear(perform: model.refreshAlerts)
    .onChange(of: filter) { currentPage = 1 }
  }

  private var pageHeader: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("提醒中心")
        .font(.title2.weight(.semibold))
      Text("规则命中与跨群地址出现的待处理信息")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 22)
    .padding(.vertical, 16)
  }

  private var toolbar: some View {
    HStack(spacing: 12) {
      Picker("显示范围", selection: $filter) {
        ForEach(AlertListFilter.allCases) { item in
          Text(item.title).tag(item)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 180)

      Text(countDescription)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)

      Spacer()

      Menu {
        Toggle(
          "启用声音提醒",
          isOn: Binding(
            get: { model.soundConfiguration.isEnabled },
            set: model.setSoundEnabled
          )
        )
        if model.isSoundTemporarilyMuted {
          Button("恢复声音") { model.muteSounds(for: 0) }
        } else {
          Button("静音 1 小时") { model.muteSounds(for: 60 * 60) }
        }
        Divider()
        Button("打开声音设置") { model.workspaceSelection = .sounds }
      } label: {
        Image(
          systemName: model.soundConfiguration.isEnabled && !model.isSoundTemporarilyMuted
            ? "speaker.wave.2" : "speaker.slash"
        )
      }
      .menuStyle(.borderlessButton)
      .frame(width: 28)
      .help("声音提醒")

      Button(action: model.refreshAlerts) {
        Image(systemName: "arrow.clockwise")
      }
      .help("刷新提醒")
      .disabled(model.isUpdatingAlerts)

      Button(action: model.acknowledgeAllAlerts) {
        Label("全部确认", systemImage: "checkmark.circle")
      }
      .disabled(model.unacknowledgedAlertCount == 0 || model.isUpdatingAlerts)
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 10)
  }

  @ViewBuilder
  private var content: some View {
    VStack(spacing: 0) {
      if let error = model.workspaceStoreError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 22)
          .padding(.vertical, 8)
        Divider()
      }

      if displayedAlerts.isEmpty {
        ContentUnavailableView {
          Label(emptyTitle, systemImage: emptySymbol)
        } description: {
          Text(emptyDescription)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(pagedAlerts) { alert in
              AlertRow(alert: alert)
                .environmentObject(model)
              Divider()
                .padding(.leading, 70)
            }
          }
        }
        PaginationBar(totalCount: displayedAlerts.count, currentPage: $currentPage)
      }
    }
  }

  private var pagedAlerts: [WorkspaceAlert] {
    displayedAlerts.pageItems(page: currentPage)
  }

  private var displayedAlerts: [WorkspaceAlert] {
    switch filter {
    case .unacknowledged:
      return model.workspaceAlerts.filter { !$0.isAcknowledged }
    case .all:
      return model.workspaceAlerts
    }
  }

  private var countDescription: String {
    switch filter {
    case .unacknowledged:
      return "待处理 \(model.unacknowledgedAlertCountLabel)"
    case .all:
      return "最近 \(model.workspaceAlerts.count) 条"
    }
  }

  private var emptyTitle: String {
    filter == .unacknowledged ? "没有待处理提醒" : "还没有提醒"
  }

  private var emptySymbol: String {
    filter == .unacknowledged ? "checkmark.circle" : "bell"
  }

  private var emptyDescription: String {
    filter == .unacknowledged
      ? "新的规则提醒和跨群地址提醒会出现在这里。"
      : "监听规则命中或同一地址跨群出现后显示记录。"
  }
}

private enum AlertListFilter: String, CaseIterable, Identifiable {
  case unacknowledged
  case all

  var id: String { rawValue }

  var title: String {
    switch self {
    case .unacknowledged: return "待处理"
    case .all: return "全部"
    }
  }
}

private struct AlertRowPresentation {
  let addressIncident: CrossGroupAddressIncident?
  let incidentSnapshot: CATokenMarketSnapshot?
  let triggerSnapshot: CATokenMarketSnapshot?
  let incidentTokenTitle: String
  let displayedTokenSnapshot: CATokenMarketSnapshot?
  let loadedSourceMessage: MessageEvent?
  let sourceTokenContext: (match: CryptoAddressMatch, snapshot: CATokenMarketSnapshot)?
  let crossGroupSourceMessages: [MessageEvent]
  let analysisSourceMessages: [MessageEvent]
  let gmgnURL: URL?
  let fomoURL: URL?
}

private struct AlertRow: View {
  @EnvironmentObject private var model: AppModel
  let alert: WorkspaceAlert

  var body: some View {
    let presentation = makePresentation()

    HStack(alignment: .top, spacing: 12) {
      alertLeadingIcon(presentation)

      VStack(alignment: .leading, spacing: 7) {
        if let incident = presentation.addressIncident {
          Text(presentation.incidentTokenTitle)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
          Text(incident.normalizedAddress)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(incident.normalizedAddress)
        } else {
          Text(alert.title)
            .font(.callout.weight(.semibold))
            .lineLimit(2)
        }

        HStack(alignment: .top, spacing: 8) {
          Text(presentation.addressIncident == nil ? alert.severity.localizedTitle : "跨群出现")
            .font(.caption.weight(.medium))
            .foregroundStyle(severityColor)
          Spacer(minLength: 4)
          WxFomoTimeLabel(
            date: alert.updatedAt,
            style: .prominent,
            alignment: .trailing
          )
          .frame(minWidth: 104, alignment: .trailing)
        }

        if let incident = presentation.addressIncident {
          addressIncidentSummary(
            incident,
            snapshot: presentation.incidentSnapshot,
            triggerSnapshot: presentation.triggerSnapshot
          )
        } else if let body = alert.body, !body.isEmpty {
          Text(body)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }

        if presentation.addressIncident == nil, let context = presentation.sourceTokenContext {
          HStack(spacing: 7) {
            Label(tokenTitle(context.snapshot), systemImage: "bitcoinsign.circle.fill")
              .font(.caption.weight(.semibold))
              .lineLimit(1)
            TokenChainBadge(chain: context.snapshot.chain)
          }
        }

        tokenExternalLinks(presentation)

        sourceSummary(presentation)

        HStack(spacing: 14) {
          if let incident = presentation.addressIncident {
            Label("\(incident.groupCount) 个群", systemImage: "person.2")
            Label("提及 \(incident.mentionCount) 次", systemImage: "number")
          } else {
            Label("出现 \(alert.occurrenceCount) 次", systemImage: "number")
          }
          Label("来源 \(alert.sourceEventIDs.count) 条", systemImage: "link")
          if let ruleID = alert.ruleID {
            Text("规则 \(shortIdentifier(ruleID))")
              .help(ruleID)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      VStack(spacing: 6) {
        if let incident = presentation.addressIncident {
          Button {
            model.presentManualBuy(for: incident)
          } label: {
            Image(systemName: "bolt.horizontal.circle.fill")
              .frame(width: 28, height: 28)
          }
          .buttonStyle(.borderless)
          .foregroundStyle(WxFomoTheme.priority)
          .help("打开快速买入；点击立即买入后直接提交")

          Button {
            model.openMemeMode(for: incident)
          } label: {
            Image(systemName: "chart.line.uptrend.xyaxis")
              .frame(width: 28, height: 28)
          }
          .buttonStyle(.borderless)
          .help("在 Meme 观察中查询")

          Button {
            copyAddress(incident.normalizedAddress)
          } label: {
            Image(systemName: "doc.on.doc")
              .frame(width: 28, height: 28)
          }
          .buttonStyle(.borderless)
          .help("复制地址")
        } else if let context = presentation.sourceTokenContext {
          Button {
            model.presentManualBuy(for: context.match, sourceMessage: presentation.loadedSourceMessage)
          } label: {
            Image(systemName: "bolt.horizontal.circle.fill")
              .frame(width: 28, height: 28)
          }
          .buttonStyle(.borderless)
          .foregroundStyle(WxFomoTheme.priority)
          .help("打开快速买入；点击立即买入后直接提交")
        }

        if alert.isAcknowledged {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .help(acknowledgedDescription)
        } else {
          Button {
            model.acknowledgeAlert(alert)
          } label: {
            Image(systemName: "checkmark.circle")
              .frame(width: 28, height: 28)
          }
          .buttonStyle(.borderless)
          .help("确认提醒")
          .disabled(model.isUpdatingAlerts)
        }
      }
      .frame(width: 36)
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 13)
    .opacity(alert.isAcknowledged ? 0.62 : 1)
    .contentShape(Rectangle())
    .contextMenu {
      if let incident = presentation.addressIncident {
        Button("快速买入") {
          model.presentManualBuy(for: incident)
        }
        Button("在 Meme 观察中查询") {
          model.openMemeMode(for: incident)
        }
        Button("复制地址") {
          copyAddress(incident.normalizedAddress)
        }
      } else if let context = presentation.sourceTokenContext {
        Button("快速买入") {
          model.presentManualBuy(for: context.match, sourceMessage: presentation.loadedSourceMessage)
        }
      }
      if let gmgnURL = presentation.gmgnURL {
        Button("在 GMGN 打开") {
          NSWorkspace.shared.open(gmgnURL)
        }
      }
      if let fomoURL = presentation.fomoURL {
        Button("在 Fomo 打开") {
          NSWorkspace.shared.open(fomoURL)
        }
      }
      if !presentation.analysisSourceMessages.isEmpty {
        Button("快速摘要来源消息") {
          Task {
            _ = await model.enqueueQuickAnalysis(messages: presentation.analysisSourceMessages)
          }
        }
      }
      if !alert.isAcknowledged {
        Button("确认提醒") {
          model.acknowledgeAlert(alert)
        }
      }
      Divider()
      Button("复制提醒概要") {
        copyAlertSummary(presentation)
      }
    }
  }

  @ViewBuilder
  private func alertLeadingIcon(_ presentation: AlertRowPresentation) -> some View {
    if let snapshot = presentation.displayedTokenSnapshot {
      ZStack(alignment: .bottomTrailing) {
        TokenArtworkView(snapshot: snapshot, size: 40, cornerRadius: 7)

        ZStack {
          Circle()
            .fill(Color(nsColor: .windowBackgroundColor))
          Image(systemName: severitySymbol)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(severityColor)
        }
        .frame(width: 16, height: 16)
        .offset(x: 3, y: 3)
      }
      .frame(width: 40, height: 40)
      .help("\(tokenTitle(snapshot)) 代币头像")
    } else {
      Image(systemName: severitySymbol)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(severityColor)
        .frame(width: 40, height: 40)
    }
  }

  @ViewBuilder
  private func tokenExternalLinks(_ presentation: AlertRowPresentation) -> some View {
    if presentation.gmgnURL != nil || presentation.fomoURL != nil {
      HStack(spacing: 7) {
        if let gmgnURL = presentation.gmgnURL {
          Link(destination: gmgnURL) {
            Label("GMGN", systemImage: "waveform.path.ecg")
          }
          .help("在浏览器打开 GMGN 代币页面")
        }
        if let fomoURL = presentation.fomoURL {
          Link(destination: fomoURL) {
            Label("Fomo", systemImage: "bolt.fill")
          }
          .help("在浏览器打开 Fomo 代币页面")
        }
      }
      .font(.caption.weight(.medium))
      .buttonStyle(.bordered)
      .controlSize(.mini)
    }
  }

  @ViewBuilder
  private func sourceSummary(_ presentation: AlertRowPresentation) -> some View {
    if presentation.addressIncident != nil, !presentation.crossGroupSourceMessages.isEmpty {
      VStack(alignment: .leading, spacing: 7) {
        ForEach(presentation.crossGroupSourceMessages, id: \.eventID) { source in
          sourceMessageSummary(source)
        }
        if alert.sourceEventIDs.count > presentation.crossGroupSourceMessages.count {
          Text("其余来源保存在本机消息库中")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
    } else if let source = presentation.loadedSourceMessage {
      VStack(alignment: .leading, spacing: 3) {
        sourceMessageSummary(source)
        if alert.sourceEventIDs.count > 1 {
          Text("另有 \(alert.sourceEventIDs.count - 1) 条来源事件")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
    } else if alert.sourceEventIDs.isEmpty {
      Label("没有关联来源事件", systemImage: "link.badge.plus")
        .font(.caption)
        .foregroundStyle(.tertiary)
    } else {
      Label(
        "\(alert.sourceEventIDs.count) 条来源事件当前未载入",
        systemImage: "exclamationmark.bubble"
      )
      .font(.caption)
      .foregroundStyle(.tertiary)
      .help("来源事件可能已被清理，或当前本地消息库无法读取。")
    }
  }

  @ViewBuilder
  private func addressIncidentSummary(
    _ incident: CrossGroupAddressIncident,
    snapshot: CATokenMarketSnapshot?,
    triggerSnapshot: CATokenMarketSnapshot?
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if let snapshot {
        HStack(spacing: 5) {
          TokenChainBadge(chain: snapshot.chain)
          Text("· \(snapshot.source.localizedTitle)")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
      } else {
        Text(incident.family == .solana ? "Solana · 币名待识别" : "网络与币名待识别")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
      }

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

      ForEach(incident.groupNames.prefix(4), id: \.self) { group in
        Label(model.displayGroupName(group), systemImage: "person.2")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if incident.groupNames.count > 4 {
        Text("另有 \(incident.groupNames.count - 4) 个已采集群")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
  }

  @ViewBuilder
  private func sourceMessageSummary(_ source: MessageEvent) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Image(systemName: "bubble.left")
          .foregroundStyle(.tertiary)
        Text(model.displayGroupName(source.group))
          .font(.caption.weight(.medium))
        Text(source.senderDisplayName ?? "未知发送者")
          .font(.caption)
          .foregroundStyle(.secondary)
        WxFomoTimeLabel(
          date: source.observedAt,
          style: .compact,
          alignment: .leading
        )
      }
      Text(source.content)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .textSelection(.enabled)
    }
  }

  private func makePresentation() -> AlertRowPresentation {
    let incident = model.crossGroupAddressIncident(forAlertID: alert.alertID)
    let loadedSources = model.sourceMessages(for: alert)
    let loadedSourceMessage = loadedSources.first
    let incidentSnapshot = incident.flatMap { model.caTokenSnapshot(for: $0) }

    var sourceTokenContext: (match: CryptoAddressMatch, snapshot: CATokenMarketSnapshot)?
    for source in loadedSources {
      for match in model.addressMatches(for: source) {
        if let snapshot = model.caTokenSnapshot(eventID: source.eventID, match: match) {
          sourceTokenContext = (match, snapshot)
          break
        }
      }
      if sourceTokenContext != nil { break }
    }

    let displayedTokenSnapshot = incidentSnapshot ?? sourceTokenContext?.snapshot
    var crossGroupSourceMessages: [MessageEvent] = []
    if let incident {
      var firstByGroup: [String: MessageEvent] = [:]
      for source in loadedSources where firstByGroup[source.group] == nil {
        firstByGroup[source.group] = source
      }
      crossGroupSourceMessages = incident.groupNames
        .compactMap { firstByGroup[$0] }
        .prefix(4)
        .map { $0 }
    }

    let analysisSourceMessages: [MessageEvent]
    if !crossGroupSourceMessages.isEmpty {
      analysisSourceMessages = crossGroupSourceMessages
    } else {
      analysisSourceMessages = loadedSourceMessage.map { [$0] } ?? []
    }

    return AlertRowPresentation(
      addressIncident: incident,
      incidentSnapshot: incidentSnapshot,
      triggerSnapshot: incident.flatMap { model.caTriggerSnapshot(for: $0) },
      incidentTokenTitle: incidentSnapshot.map(tokenTitle) ?? "CA 待识别",
      displayedTokenSnapshot: displayedTokenSnapshot,
      loadedSourceMessage: loadedSourceMessage,
      sourceTokenContext: sourceTokenContext,
      crossGroupSourceMessages: crossGroupSourceMessages,
      analysisSourceMessages: analysisSourceMessages,
      gmgnURL: displayedTokenSnapshot.flatMap {
        TokenExternalLinks.gmgn(chain: $0.chain, address: $0.address)
      },
      fomoURL: displayedTokenSnapshot.flatMap {
        TokenExternalLinks.fomo(chain: $0.chain, address: $0.address)
      }
    )
  }

  private func copyAddress(_ address: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(address, forType: .string)
  }

  private func copyAlertSummary(_ presentation: AlertRowPresentation) {
    let detail = presentation.addressIncident?.normalizedAddress ?? alert.body ?? ""
    let token = presentation.incidentSnapshot.map {
      "\(tokenTitle($0)) · \($0.chain.localizedTitle)"
    } ?? presentation.sourceTokenContext.map {
      "\(tokenTitle($0.snapshot)) · \($0.snapshot.chain.localizedTitle)"
    }
    let triggerMarket = presentation.triggerSnapshot
      .map { "提示 \(formattedUSD($0.marketCapUSD))" }
    let text = [alert.title, token, triggerMarket, detail]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func tokenTitle(_ snapshot: CATokenMarketSnapshot) -> String {
    if !snapshot.symbol.isEmpty, !snapshot.name.isEmpty,
      snapshot.symbol.caseInsensitiveCompare(snapshot.name) != .orderedSame
    {
      return "\(snapshot.symbol) · \(snapshot.name)"
    }
    if !snapshot.symbol.isEmpty { return snapshot.symbol }
    if !snapshot.name.isEmpty { return snapshot.name }
    return "未知代币"
  }

  private func formattedUSD(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "未返回" }
    let magnitude = abs(value)
    if magnitude >= 1_000_000_000 {
      return "$" + (value / 1_000_000_000).formatted(
        .number.precision(.fractionLength(1...2))
      ) + "B"
    }
    if magnitude >= 1_000_000 {
      return "$" + (value / 1_000_000).formatted(
        .number.precision(.fractionLength(1...2))
      ) + "M"
    }
    if magnitude >= 1_000 {
      return "$" + (value / 1_000).formatted(
        .number.precision(.fractionLength(1...2))
      ) + "K"
    }
    return value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
  }

  private var severitySymbol: String {
    switch alert.severity {
    case .information: return "info.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .critical: return "exclamationmark.octagon.fill"
    }
  }

  private var severityColor: Color {
    switch alert.severity {
    case .information: return .blue
    case .warning: return .orange
    case .critical: return .red
    }
  }

  private var acknowledgedDescription: String {
    guard let acknowledgedAt = alert.acknowledgedAt else { return "已确认" }
    return "已于 \(acknowledgedAt.formatted(date: .abbreviated, time: .shortened)) 确认"
  }

  private func shortIdentifier(_ identifier: String) -> String {
    identifier.count > 10 ? String(identifier.prefix(10)) : identifier
  }
}
