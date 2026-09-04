import AppKit
import Charts
import SwiftUI
import WxFomoCore

struct ContentView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    NavigationSplitView {
      SidebarView()
        .navigationSplitViewColumnWidth(286)
    } detail: {
      detail
    }
    .tint(WxFomoTheme.signal)
    .background(Color(nsColor: .windowBackgroundColor))
    .background(WxFomoWindowChrome())
    .sheet(item: $model.manualBuyRequest) { request in
      ManualBuySheet(context: request)
        .environmentObject(model)
    }
    .sheet(item: $model.manualSellRequest) { request in
      ManualSellSheet(context: request)
        .environmentObject(model)
    }
  }

  @ViewBuilder
  private var detail: some View {
    switch model.workspaceSelection {
    case .inbox, .captured, .group:
      MessageFeedView()
    case .analyses:
      AnalysisWorkspaceView()
    case .alerts:
      AlertsWorkspaceView()
    case .meme:
      MemeWorkspaceView()
    case .market:
      MarketTrendWorkspaceView()
    case .rules:
      RulesWorkspaceView()
    case .trading:
      TradeWorkspaceView()
    case .automations:
      AutomationsWorkspaceView()
    case .sounds:
      SoundSettingsView()
    case .providers:
      ProviderWorkspaceView()
    case .diagnostics:
      DiagnosticsWorkspaceView()
    }
  }

}

private struct SidebarView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 11) {
          WxFomoBrandMark()
            .frame(width: 42, height: 42)
            .shadow(color: .black.opacity(0.16), radius: 5, y: 2)

          VStack(alignment: .leading, spacing: 1) {
            Text("wxFomo")
              .font(.system(size: 21, weight: .bold, design: .rounded))
            Text("群聊信号台")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        HStack(spacing: 7) {
          Circle()
            .fill(stateColor)
            .frame(width: 7, height: 7)
          Text(model.listenerState.title)
            .fontWeight(.medium)
          Spacer()
          Text("监听 \(model.groups.count) 个群")
            .foregroundStyle(.secondary)
        }
        .font(.caption)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 18)
      .padding(.top, 16)
      .padding(.bottom, 12)

      List(selection: $model.workspaceSelection) {
        Section("消息") {
          Label("收件箱", systemImage: "tray.full")
            .tag(WorkspaceSelection.inbox)
          HStack {
            Label("重点捕捉", systemImage: "scope")
            Spacer()
            if model.capturedCount > 0 {
              SidebarCountBadge(value: "\(model.capturedCount)", color: WxFomoTheme.priority)
            }
          }
          .tag(WorkspaceSelection.captured)

          HStack {
            Label("提醒中心", systemImage: "bell.badge")
            Spacer()
            if model.unacknowledgedAlertCount > 0 {
              SidebarCountBadge(
                value: model.unacknowledgedAlertCountLabel,
                color: WxFomoTheme.priority
              )
            }
          }
          .tag(WorkspaceSelection.alerts)
        }

        Section {
          ForEach(model.groups, id: \.self) { group in
            HStack(spacing: 8) {
              Label(model.displayGroupName(group), systemImage: "person.3")
                .lineLimit(1)
              Spacer(minLength: 6)
              if !model.isListening {
                Button {
                  model.removeGroup(group)
                } label: {
                  Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("移除群聊")
              }
            }
            .contextMenu {
              Button("打开此群") {
                model.workspaceSelection = .group(group)
              }
              Button("复制真实群名") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(group, forType: .string)
              }
              Button(model.redactsGroupNames ? "显示真实群名" : "隐藏群名") {
                model.redactsGroupNames.toggle()
              }
            }
            .tag(WorkspaceSelection.group(group))
          }

          HStack(spacing: 7) {
            TextField("输入完整群名", text: $model.groupDraft)
              .textFieldStyle(.roundedBorder)
              .onSubmit { model.addGroup() }
              .disabled(model.isListening)
            Button(action: model.addGroup) {
              Image(systemName: "plus.circle.fill")
                .font(.system(size: 17))
            }
            .buttonStyle(.plain)
            .help("添加群聊")
            .disabled(
              model.isListening
                || model.groupDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
          }
          .padding(.vertical, 4)
        } header: {
          HStack(spacing: 8) {
            Text("监听群")
            Spacer(minLength: 8)
            Button {
              model.redactsGroupNames.toggle()
            } label: {
              Label(
                model.redactsGroupNames ? "全部显示" : "全部隐藏",
                systemImage: model.redactsGroupNames ? "eye" : "eye.slash"
              )
              .font(.caption2.weight(.medium))
              .fixedSize()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(model.redactsGroupNames ? WxFomoTheme.priority : .secondary)
            .help(model.redactsGroupNames ? "显示全部真实群名" : "将全部群名显示为 ***")
            .accessibilityLabel(model.redactsGroupNames ? "全部显示群名" : "全部隐藏群名")
          }
          .frame(maxWidth: .infinity)
        }

        Section("工作台") {
          Label("Meme 观察", systemImage: "waveform.path.ecg.rectangle")
            .tag(WorkspaceSelection.meme)
          Label("市场趋势", systemImage: "chart.line.uptrend.xyaxis")
            .tag(WorkspaceSelection.market)
          Label("分析记录", systemImage: "sparkles.rectangle.stack")
            .tag(WorkspaceSelection.analyses)
          Label("监控规则", systemImage: "line.3.horizontal.decrease")
            .tag(WorkspaceSelection.rules)
          Label("交易工作台", systemImage: "arrow.left.arrow.right.square")
            .tag(WorkspaceSelection.trading)
          Label("自动化交易", systemImage: "gearshape.arrow.triangle.2.circlepath")
            .tag(WorkspaceSelection.automations)
        }

        Section("设置") {
          Label("声音与提醒", systemImage: "speaker.wave.2")
            .tag(WorkspaceSelection.sounds)
          Label("配置中心", systemImage: "gearshape.2")
            .tag(WorkspaceSelection.providers)
          Label("运行诊断", systemImage: "waveform.path.ecg")
            .tag(WorkspaceSelection.diagnostics)
        }

        Section("采集状态") {
          StatusRow(
            title: "微信",
            detail: weChatDetail,
            isReady: model.doctorReport?.weChatRunning == true
          )
          StatusRow(
            title: "通知读取",
            detail: notificationDetail,
            isReady: model.doctorReport?.notificationDatabaseReadable == true
          )
          if let diagnostic = model.historyDiagnostic {
            StatusRow(
              title: "历史样本",
              detail: "微信 \(diagnostic.decodedNotificationCount)，群命中 \(diagnostic.matchedGroupCount)，附件 \(diagnostic.attachmentCount)",
              isReady: diagnostic.matchedGroupCount > 0
            )
          }
          if let health = model.notificationHealth {
            StatusRow(
              title: "定时补扫",
              detail: health.lastError == nil ? successfulScanDetail(health) : "失败后自动重试",
              isReady: health.lastError == nil
            )
          }

          Button(action: model.refreshStatus) {
            Label("重新检查", systemImage: "arrow.clockwise")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
        }
      }
      .listStyle(.sidebar)
      .onChange(of: model.workspaceSelection) {
        model.workspaceSelectionDidChange()
      }

      VStack(alignment: .leading, spacing: 10) {
        if model.doctorReport?.notificationDatabaseReadable != true {
          Button(action: model.openFullDiskAccessSettings) {
            Label("打开完全磁盘访问设置", systemImage: "lock.open")
              .frame(maxWidth: .infinity)
          }
          .controlSize(.large)
        }

        Toggle("启动时载入最近通知", isOn: $model.includeExisting)
          .font(.caption)
          .disabled(model.isListening)

        Button(action: model.toggleListening) {
          Label(
            model.isListening ? "停止监听" : "开始监听",
            systemImage: model.isListening ? "stop.fill" : "play.fill"
          )
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(model.isListening ? WxFomoTheme.priority : WxFomoTheme.signal)
      }
      .padding(14)
      .background(Color(nsColor: .underPageBackgroundColor).opacity(0.72))
    }
  }

  private var stateColor: Color {
    switch model.listenerState {
    case .idle: return .secondary
    case .starting: return .orange
    case .listening: return .green
    case .recovering: return .orange
    case .failed: return .red
    }
  }

  private var weChatDetail: String {
    guard let report = model.doctorReport else { return "检查中" }
    if !report.weChatInstalled { return "未安装" }
    let version = report.weChatVersion.map { " \($0)" } ?? ""
    return report.weChatRunning ? "运行中\(version)" : "未运行\(version)"
  }

  private var notificationDetail: String {
    guard model.doctorReport?.notificationDatabaseReadable == true else { return "需要授权" }
    guard let rowID = model.notificationLatestRowID else { return "读取异常" }
    return rowID > 0 ? "可读取" : "可读取，尚无微信通知"
  }

  private func successfulScanDetail(_ health: NotificationMonitorHealth) -> String {
    guard let scannedAt = health.lastSuccessfulScanAt else {
      return "等待首次补扫，rowid \(health.lastRowID)"
    }
    return "\(scannedAt.formatted(date: .omitted, time: .standard))，rowid \(health.lastRowID)"
  }
}

private struct SidebarCountBadge: View {
  let value: String
  let color: Color

  var body: some View {
    Text(value)
      .font(.caption2.monospacedDigit().weight(.semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color.opacity(0.12), in: Capsule())
  }
}

private struct StatusRow: View {
  let title: String
  let detail: String
  let isReady: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        .foregroundStyle(isReady ? .green : .orange)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct MessageFeedView: View {
  @EnvironmentObject private var model: AppModel
  @State private var showsFilters = false
  @State private var analysisSnapshot: AnalysisComposerSnapshot?
  @State private var showsQuantitativeDetails = false
  @State private var isSelectingMessages = false
  @State private var selectedMessageIDs = Set<String>()
  @State private var isSubmittingQuickAnalysis = false

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if model.messageContextFocus == nil {
        rangeToolbar
      } else {
        contextBanner
      }
      Divider()
      addressToolbar
      Divider()
      if model.messageContextFocus == nil {
        quantitativeSummary
      }
      storeWarning
      diagnostics
      feed
      if isSelectingMessages {
        Divider()
        selectionToolbar
      }
      Divider()
      statusBar
    }
    .searchable(text: $model.searchText, placement: .toolbar, prompt: "搜索发送者或内容")
    .onChange(of: model.searchText) {
      clearMessageSelection()
      model.scheduleMessageReload()
    }
    .onChange(of: model.workspaceSelection) { clearMessageSelection() }
    .onChange(of: model.addressFilter) { clearMessageSelection() }
    .onChange(of: model.focusedAddress) { clearMessageSelection() }
    .sheet(item: $analysisSnapshot) { snapshot in
      AnalysisComposerView(snapshot: snapshot)
        .environmentObject(model)
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          withAnimation(.easeInOut(duration: 0.16)) {
            isSelectingMessages.toggle()
            if !isSelectingMessages { selectedMessageIDs.removeAll() }
          }
        } label: {
          Image(systemName: isSelectingMessages ? "xmark.circle.fill" : "checklist")
        }
        .help(isSelectingMessages ? "结束消息选择" : "选择多条消息")

        Button {
          quickAnalyze(model.visibleMessages)
        } label: {
          if isSubmittingQuickAnalysis {
            ProgressView()
              .controlSize(.small)
          } else {
            Label("快速摘要", systemImage: "sparkles")
          }
        }
        .disabled(model.visibleMessages.isEmpty || isSubmittingQuickAnalysis)
        .help("使用默认 AI 服务快速摘要当前消息")

        Menu {
          Button("提取重要信息") {
            quickAnalyze(model.visibleMessages, mode: .importantInformation)
          }
          Button("风险与机会") {
            quickAnalyze(model.visibleMessages, mode: .risksAndOpportunities)
          }
          Button("待办与时间点") {
            quickAnalyze(model.visibleMessages, mode: .actionItems)
          }
          Divider()
          Button("更多分析设置…") {
            analyze(messages: model.visibleMessages, rangeTitle: model.timePreset.title)
          }
          Button("查看分析记录") {
            model.workspaceSelection = .analyses
          }
        } label: {
          Image(systemName: "chevron.down.circle")
        }
        .disabled(model.visibleMessages.isEmpty || isSubmittingQuickAnalysis)
        .help("选择分析方式")

        Button {
          showsFilters.toggle()
        } label: {
          Image(
            systemName: model.activeFilterCount > 0
              ? "line.3.horizontal.decrease.circle.fill"
              : "line.3.horizontal.decrease.circle"
          )
        }
        .help("筛选与捕捉")
        .popover(isPresented: $showsFilters, arrowEdge: .bottom) {
          FilterPanel()
            .environmentObject(model)
        }

        Button(action: model.refreshStatus) {
          Image(systemName: "arrow.clockwise")
        }
        .help("刷新本机状态")

        Button(action: model.markCurrentMessagesReviewed) {
          Image(systemName: "checkmark.circle")
        }
        .help(
          model.canMarkCurrentMessagesReviewed
            ? "标记当前范围已查看"
            : "请先清除筛选并载入全部匹配消息"
        )
        .disabled(!model.canMarkCurrentMessagesReviewed)
      }
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 5) {
        Text(model.selectedTitle)
          .font(.title2.weight(.bold))
        Text(feedSubtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 12)

      VStack(alignment: .trailing, spacing: 6) {
        Label(
          model.isListening ? "持续捕捉中" : "捕捉已暂停",
          systemImage: model.isListening ? "dot.radiowaves.left.and.right" : "pause.circle"
        )
        .foregroundStyle(model.isListening ? WxFomoTheme.signal : .secondary)

        Label("最新优先", systemImage: "arrow.down.to.line")
          .foregroundStyle(.secondary)
      }
      .font(.caption.weight(.medium))
    }
    .padding(.horizontal, 22)
    .padding(.top, 15)
    .padding(.bottom, 13)
  }

  private var rangeToolbar: some View {
    HStack(spacing: 12) {
      Picker("时间范围", selection: $model.timePreset) {
        ForEach(MessageTimePreset.allCases) { preset in
          Text(preset.title).tag(preset)
        }
      }
      .labelsHidden()
      .frame(width: 150)
      .onChange(of: model.timePreset) { model.scheduleMessageReload() }

      if model.timePreset == .custom {
        DatePicker(
          "开始",
          selection: $model.customRangeStart,
          displayedComponents: [.date, .hourAndMinute]
        )
        .labelsHidden()
        .onChange(of: model.customRangeStart) { model.scheduleMessageReload() }
        Image(systemName: "arrow.right")
          .foregroundStyle(.tertiary)
        DatePicker(
          "结束",
          selection: $model.customRangeEnd,
          displayedComponents: [.date, .hourAndMinute]
        )
        .labelsHidden()
        .onChange(of: model.customRangeEnd) { model.scheduleMessageReload() }
      }

      Spacer(minLength: 0)
      Label("本机通知样本", systemImage: "internaldrive")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 10)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
  }

  @ViewBuilder
  private var contextBanner: some View {
    if let focus = model.messageContextFocus {
      HStack(spacing: 12) {
        Image(systemName: "location.fill")
          .foregroundStyle(WxFomoTheme.priority)
          .frame(width: 24, height: 24)
          .background(WxFomoTheme.priority.opacity(0.12), in: Circle())

        VStack(alignment: .leading, spacing: 2) {
          Text("正在定位原始消息")
            .font(.callout.weight(.semibold))
          Text(
            "\(model.displayGroupName(focus.group)) · \(focus.observedAt.formatted(date: .abbreviated, time: .standard)) · 前后各最多 30 条"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        }

        Spacer(minLength: 12)

        Text("普通筛选暂时停用")
          .font(.caption)
          .foregroundStyle(.secondary)

        Button(action: model.closeMessageContext) {
          Label("返回原视图", systemImage: "arrow.uturn.backward")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 9)
      .background(WxFomoTheme.priority.opacity(0.055))
    }
  }

  private var addressToolbar: some View {
    HStack(spacing: 10) {
      Label("内容筛选", systemImage: "line.3.horizontal.decrease")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      AddressFilterTabs(compact: true)

      Divider()
        .frame(height: 18)

      Menu {
        Button {
          model.workspaceSelection = .inbox
        } label: {
          Label("所有监听群", systemImage: "tray.full")
        }
        Divider()
        ForEach(model.groups, id: \.self) { group in
          Button {
            model.workspaceSelection = .group(group)
          } label: {
            Label(model.displayGroupName(group), systemImage: "person.3")
          }
        }
      } label: {
        Label(quickGroupTitle, systemImage: "person.3")
          .lineLimit(1)
      }
      .menuStyle(.borderlessButton)
      .frame(maxWidth: 180)
      .help("快速切换群聊")

      Button {
        model.redactsGroupNames.toggle()
      } label: {
        Image(systemName: model.redactsGroupNames ? "eye.slash.fill" : "eye")
          .frame(width: 22, height: 22)
      }
      .buttonStyle(.plain)
      .foregroundStyle(model.redactsGroupNames ? WxFomoTheme.priority : .secondary)
      .help(model.redactsGroupNames ? "显示真实群名" : "隐藏群名")
      .accessibilityLabel(model.redactsGroupNames ? "显示真实群名" : "隐藏群名")

      if let focusedAddress = model.focusedAddress {
        HStack(spacing: 6) {
          Text(focusedAddress.network.shortTitle)
            .font(.caption2.weight(.bold))
            .foregroundStyle(focusedAddress.network.tintColor)
          Text(focusedAddress.shortDisplay)
            .font(.caption.monospaced())
          Button {
            model.openMemeMode(for: focusedAddress)
          } label: {
            Image(systemName: "chart.line.uptrend.xyaxis")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("查询 Meme 数据")
          Button(action: model.clearAddressFocus) {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("清除地址筛选")
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(
          focusedAddress.network.tintColor.opacity(0.09),
          in: RoundedRectangle(cornerRadius: 5)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 5)
            .stroke(focusedAddress.network.tintColor.opacity(0.24))
        }
      }

      Spacer(minLength: 8)

      Text("当前已加载 · \(model.visibleMessages.count.formatted()) 条")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: true, vertical: false)

      if model.addressFilter != .all || model.focusedAddress != nil {
        Button {
          model.setAddressFilter(.all)
        } label: {
          Image(systemName: "line.3.horizontal.decrease.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("清除地址筛选")
      }
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 8)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  @ViewBuilder
  private var quantitativeSummary: some View {
    if let analytics = model.flowAnalytics {
      VStack(spacing: 0) {
        let statistics = analytics.statistics
        HStack(spacing: 12) {
          Label("信息概览", systemImage: "chart.bar.xaxis")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

          if !showsQuantitativeDetails {
            Divider()
              .frame(height: 13)
            InlineRangeMetric(title: "已采集", value: statistics.capturedCount)
            if let management = model.managementMetrics {
              InlineRangeMetric(title: "待查看", value: management.pendingReviewCount)
              InlineRangeMetric(title: "重点", value: rate(management.priorityRate))
              InlineRangeMetric(title: "抑制", value: rate(management.suppressionRate))
            }
          }

          Spacer()
          if model.hasMoreMessages {
            Text("已加载 \(model.messages.count) / 匹配 \(analytics.statistics.capturedCount)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          Button {
            withAnimation(.easeInOut(duration: 0.16)) {
              showsQuantitativeDetails.toggle()
            }
          } label: {
            Image(
              systemName: showsQuantitativeDetails
                ? "chevron.up"
                : "chevron.down"
            )
          }
          .buttonStyle(.plain)
          .help(showsQuantitativeDetails ? "收起量化详情" : "展开量化详情")
        }
        .help("统计只基于本机实际捕捉到的通知")

        if showsQuantitativeDetails {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 94, maximum: 150), spacing: 12)],
            alignment: .leading,
            spacing: 10
          ) {
            RangeMetric(title: "已采集", value: statistics.capturedCount)
            if let previous = model.previousFlowAnalytics {
              RangeMetric(
                title: "前一等长区间",
                value: previous.statistics.capturedCount
              )
            }
            if let management = model.managementMetrics {
              RangeMetric(
                title: pendingReviewTitle(management),
                value: management.pendingReviewCount
              )
              RangeMetric(
                title: "当前重点 · \(management.priorityCapturedCount) 条",
                value: rate(management.priorityRate)
              )
              RangeMetric(
                title: "已抑制 · \(management.suppressedCapturedCount) 条",
                value: rate(management.suppressionRate)
              )
            }
            RangeMetric(title: "群名", value: statistics.conversationCount)
            RangeMetric(title: "可识别发送者键", value: statistics.senderCount)
            RangeMetric(
              title: "发送者未知消息",
              value: percentage(statistics.unknownSenderCount, of: statistics.capturedCount)
            )
            RangeMetric(
              title: "媒体占位",
              value: percentage(statistics.mediaPlaceholderCount, of: statistics.capturedCount)
            )
            RangeMetric(
              title: "峰值 / \(analytics.bucketGranularity.localizedShortTitle)",
              value: analytics.peakBucketCount
            )
          }
          .padding(.top, 8)

          if model.previousFlowAnalytics != nil {
            Text("等长区间变化只比较本机采集样本，未校正监听暂停、专注模式或通知设置变化。")
              .font(.caption)
              .foregroundStyle(.tertiary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, 6)
          }

          if model.managementMetrics != nil {
            Text("待查看表示尚未越过 wxFomo 的逐群查看位置，不是微信未读；重点与抑制按当前规则配置计算。")
              .font(.caption)
              .foregroundStyle(.tertiary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, 4)
          }

          if !analytics.timeBuckets.isEmpty {
            Divider()
              .padding(.top, 10)
            MessageFlowDashboard(analytics: analytics)
              .padding(.top, 10)
          }
        }
      }
      .padding(.horizontal, 22)
      .padding(.vertical, showsQuantitativeDetails ? 10 : 7)
      .background(WxFomoTheme.signal.opacity(0.045))
    }
  }

  private func percentage(_ value: Int, of total: Int) -> String {
    guard total > 0 else { return "0%" }
    return (Double(value) / Double(total)).formatted(.percent.precision(.fractionLength(0)))
  }

  private func rate(_ value: Double?) -> String {
    guard let value else { return "—" }
    return value.formatted(.percent.precision(.fractionLength(0)))
  }

  private func pendingReviewTitle(_ metrics: MessageManagementMetrics) -> String {
    guard metrics.pendingReviewCount > 0,
      let oldest = metrics.oldestPendingReviewObservedAt
    else {
      return "wxFomo 待查看"
    }
    return "待查看 · 最老 \(compactAge(since: oldest))"
  }

  private func compactAge(since date: Date) -> String {
    let seconds = max(0, Date().timeIntervalSince(date))
    if seconds < 60 { return "刚刚" }
    if seconds < 60 * 60 { return "\(Int(seconds / 60)) 分钟" }
    if seconds < 24 * 60 * 60 { return "\(Int(seconds / 3_600)) 小时" }
    return "\(Int(seconds / 86_400)) 天"
  }

  @ViewBuilder
  private var storeWarning: some View {
    if let error = model.messageStoreError {
      Label("本地消息库：\(error)", systemImage: "externaldrive.badge.exclamationmark")
        .font(.caption)
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.06))
    }
  }

  @ViewBuilder
  private var diagnostics: some View {
    if let health = model.notificationHealth {
      Group {
        if showsQuantitativeDetails {
          VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 14) {
              DiagnosticMetric(title: "新增记录", value: health.scannedRecordCount)
              DiagnosticMetric(title: "识别微信", value: health.identifiedWeChatNotificationCount)
              DiagnosticMetric(title: "解码成功", value: health.decodedNotificationCount)
              DiagnosticMetric(title: "群名命中", value: health.groupMatchedNotificationCount)
              DiagnosticMetric(title: "已发出", value: health.matchedEventCount)
              DiagnosticMetric(title: "更新补获", value: health.updatedNotificationRecoveryCount)
              Spacer(minLength: 0)
              Text(activityTime(health))
                .foregroundStyle(.tertiary)
            }
            Label(model.notificationDiagnosticText, systemImage: diagnosticSymbol(health))
              .foregroundStyle(diagnosticColor(health))
              .lineLimit(2)
          }
        } else {
          HStack(spacing: 8) {
            Label(model.notificationDiagnosticText, systemImage: diagnosticSymbol(health))
              .foregroundStyle(diagnosticColor(health))
              .lineLimit(1)
            Spacer(minLength: 8)
            Text(activityTime(health))
              .foregroundStyle(.tertiary)
              .fixedSize(horizontal: true, vertical: false)
          }
        }
      }
      .font(.caption)
      .padding(.horizontal, 22)
      .padding(.vertical, showsQuantitativeDetails ? 9 : 5)
      .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
  }

  private var feed: some View {
    let displayedMessages = model.visibleMessages
    return Group {
      if displayedMessages.isEmpty {
        VStack(spacing: 16) {
          ContentUnavailableView {
            Label(emptyTitle, systemImage: emptySymbol)
          } description: {
            Text(emptyDescription)
          }
          if model.hasMoreMessages {
            loadMoreButton
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(displayedMessages, id: \.eventID) { event in
                feedRow(for: event)
              }
              if model.hasMoreMessages {
                loadMoreButton
              }
            }
          }
          .onChange(of: displayedMessages.first?.eventID) {
            guard model.messageContextFocus == nil else { return }
            guard let latestID = displayedMessages.first?.eventID else { return }
            withAnimation(.easeOut(duration: 0.2)) {
              proxy.scrollTo(latestID, anchor: .top)
            }
          }
          .onChange(of: contextScrollTarget) {
            guard let target = contextScrollTarget else { return }
            DispatchQueue.main.async {
              withAnimation(.easeOut(duration: 0.28)) {
                proxy.scrollTo(target, anchor: .center)
              }
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private func feedRow(for event: MessageEvent) -> some View {
    MessageRow(
      event: event,
      isCaptured: model.isCaptured(event),
      showsGroup: showsGroupInRows,
      addresses: model.addressMatches(for: event),
      webLinks: model.webLinks(for: event),
      isSelectionMode: isSelectingMessages,
      isSelected: selectedMessageIDs.contains(event.eventID),
      isContextTarget: model.messageContextFocus?.eventID == event.eventID,
      onToggleSelection: { toggleSelection(for: event) },
      onSelectMessage: { selectMessage(event) },
      onFilterAddress: { match, scope in
        filterMessages(matching: match, from: event, scope: scope)
      },
      onQueryAddress: { match in
        model.openMemeMode(for: match, sourceMessage: event)
      },
      onBuyAddress: { match in
        model.presentManualBuy(for: match, sourceMessage: event)
      },
      onOpenAddressContext: {
        model.openMessageContext(for: event)
      },
      onQuickAnalyze: { quickAnalyze([event]) },
      onAdvancedAnalyze: {
        analyze(messages: [event], rangeTitle: "单条消息")
      },
      onOpenGroup: {
        model.workspaceSelection = .group(event.group)
      }
    )
    .id(event.eventID)
    Divider()
      .padding(.leading, isSelectingMessages ? 108 : 76)
  }

  private var feedSubtitle: String {
    let count = model.visibleMessages.count.formatted()
    if model.messageContextFocus != nil {
      return "已加载 \(count) 条 · 原消息上下文"
    }
    switch model.workspaceSelection {
    case .inbox:
      return "已加载 \(count) 条 · 所有监听群"
    case .captured:
      return "已加载 \(count) 条 · 重点规则命中"
    case .group:
      return "已加载 \(count) 条 · 当前群聊"
    case .analyses, .alerts, .meme, .market, .rules, .trading, .automations, .sounds, .providers,
      .diagnostics:
      return "已加载 \(count) 条"
    }
  }

  private var contextScrollTarget: String? {
    guard let target = model.messageContextFocus?.eventID,
      model.visibleMessages.contains(where: { $0.eventID == target })
    else {
      return nil
    }
    return target
  }

  private var quickGroupTitle: String {
    switch model.workspaceSelection {
    case .inbox: return "所有监听群"
    case .captured: return "重点捕捉"
    case .group(let group): return model.displayGroupName(group)
    case .analyses, .alerts, .meme, .market, .rules, .trading, .automations, .sounds, .providers,
      .diagnostics:
      return "选择群聊"
    }
  }

  private var showsGroupInRows: Bool {
    if case .group = model.workspaceSelection { return false }
    return true
  }

  private var loadMoreButton: some View {
    Button(action: model.loadMoreMessages) {
      if model.isLoadingMessages {
        ProgressView()
          .controlSize(.small)
      } else {
        Label("载入更早消息", systemImage: "arrow.down.to.line")
      }
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .padding(.vertical, 14)
    .disabled(model.isLoadingMessages)
  }

  private var selectionToolbar: some View {
    HStack(spacing: 10) {
      Label("已选 \(selectedMessages.count) 条", systemImage: "checkmark.circle.fill")
        .font(.callout.weight(.semibold))
        .foregroundStyle(selectedMessages.isEmpty ? .secondary : WxFomoTheme.signal)

      Button(allVisibleMessagesSelected ? "取消全选" : "全选当前结果") {
        toggleAllVisibleMessages()
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .disabled(model.visibleMessages.isEmpty)

      Spacer()

      Button {
        copySelectedMessages()
      } label: {
        Label("复制", systemImage: "doc.on.doc")
      }
      .disabled(selectedMessages.isEmpty)

      Button {
        quickAnalyze(selectedMessages)
      } label: {
        Label("快速摘要选中消息", systemImage: "sparkles")
      }
      .buttonStyle(.borderedProminent)
      .disabled(selectedMessages.isEmpty || isSubmittingQuickAnalysis)

      Menu {
        Button("更多分析设置…") {
          analyzeSelectedMessages()
        }
        Button("提取重要信息") {
          quickAnalyze(selectedMessages, mode: .importantInformation)
        }
        Button("风险与机会") {
          quickAnalyze(selectedMessages, mode: .risksAndOpportunities)
        }
      } label: {
        Image(systemName: "chevron.down.circle")
      }
      .disabled(selectedMessages.isEmpty || isSubmittingQuickAnalysis)
      .help("选择分析方式")

      Button {
        withAnimation(.easeInOut(duration: 0.16)) {
          isSelectingMessages = false
          selectedMessageIDs.removeAll()
        }
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("结束消息选择")
    }
    .padding(.horizontal, 18)
    .frame(height: 42)
    .background(WxFomoTheme.signal.opacity(0.055))
  }

  private var statusBar: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(model.isListening ? Color.green : Color.secondary.opacity(0.55))
        .frame(width: 7, height: 7)
      Text(model.displayedActivityText)
        .lineLimit(1)
      Spacer()
      Text(healthSummary)
        .foregroundStyle(.tertiary)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 16)
    .frame(height: 32)
    .background(.bar)
  }

  private var healthSummary: String {
    guard let health = model.notificationHealth else {
      if let capabilities = model.messageStoreCapabilities {
        return "本机持久化 · \(capabilities.journalMode.uppercased())"
      }
      return "本地消息库不可用"
    }
    let lastScan = health.lastSuccessfulScanAt?.formatted(date: .omitted, time: .standard) ?? "等待补扫"
    return "补扫 \(lastScan) · rowid \(health.lastRowID) · 恢复 \(health.recoveryCount)"
  }

  private var emptyTitle: String {
    if model.groups.isEmpty { return "还没有监听群" }
    if model.addressFilter == .webLink { return "没有链接匹配" }
    if model.addressFilter != .all || model.focusedAddress != nil { return "没有地址匹配" }
    if !model.searchText.isEmpty { return "没有匹配结果" }
    if case .failed = model.listenerState { return "监听需要处理" }
    return model.isListening ? "等待新消息" : "监听尚未启动"
  }

  private var emptySymbol: String {
    if model.groups.isEmpty { return "person.3.sequence" }
    if model.addressFilter != .all || model.focusedAddress != nil { return "link.badge.plus" }
    if !model.searchText.isEmpty { return "magnifyingglass" }
    if case .failed = model.listenerState { return "exclamationmark.triangle" }
    return model.isListening ? "wave.3.right" : "tray"
  }

  private var emptyDescription: String {
    if model.groups.isEmpty { return "在左侧输入微信群的完整名称。" }
    if model.addressFilter == .webLink {
      return model.hasMoreMessages
        ? "当前已加载消息中没有 HTTP/HTTPS 链接，可载入更早消息后继续筛选。"
        : "当前消息范围中没有检测到明确的 HTTP/HTTPS 链接。"
    }
    if model.addressFilter != .all || model.focusedAddress != nil {
      return model.hasMoreMessages
        ? "当前已加载消息中没有命中，可载入更早消息后继续筛选。"
        : "当前消息范围中没有检测到对应的地址格式。"
    }
    if !model.searchText.isEmpty { return "换一个关键词，或切换到全部消息。" }
    if case .failed(let message) = model.listenerState { return message }
    return model.isListening
      ? model.notificationDiagnosticText
      : "点击左下角的开始监听。"
  }

  private var selectedMessages: [MessageEvent] {
    model.visibleMessages.filter { selectedMessageIDs.contains($0.eventID) }
  }

  private var allVisibleMessagesSelected: Bool {
    !model.visibleMessages.isEmpty
      && model.visibleMessages.allSatisfy { selectedMessageIDs.contains($0.eventID) }
  }

  private func toggleSelection(for event: MessageEvent) {
    if selectedMessageIDs.contains(event.eventID) {
      selectedMessageIDs.remove(event.eventID)
    } else {
      selectedMessageIDs.insert(event.eventID)
    }
  }

  private func selectMessage(_ event: MessageEvent) {
    isSelectingMessages = true
    selectedMessageIDs.insert(event.eventID)
  }

  private func toggleAllVisibleMessages() {
    let visibleIDs = Set(model.visibleMessages.map(\.eventID))
    if visibleIDs.isSubset(of: selectedMessageIDs) {
      selectedMessageIDs.subtract(visibleIDs)
    } else {
      selectedMessageIDs.formUnion(visibleIDs)
    }
  }

  private func clearMessageSelection() {
    selectedMessageIDs.removeAll()
  }

  private func copySelectedMessages() {
    let text = selectedMessages.map { event in
      let sender = event.senderDisplayName ?? "未知发送者"
      let time = event.observedAt.formatted(date: .numeric, time: .standard)
      return "[\(time)] [\(model.displayGroupName(event.group))] \(sender)\n\(event.content)"
    }.joined(separator: "\n\n")
    guard !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func analyzeSelectedMessages() {
    let messages = selectedMessages
    guard !messages.isEmpty else { return }
    analyze(
      messages: messages,
      rangeTitle: "手动选择 · \(messages.count) 条 · \(model.timePreset.title)"
    )
  }

  private func analyze(messages: [MessageEvent], rangeTitle: String) {
    guard !messages.isEmpty else { return }
    analysisSnapshot = AnalysisComposerSnapshot(messages: messages, rangeTitle: rangeTitle)
  }

  private func quickAnalyze(
    _ messages: [MessageEvent],
    mode: AIAnalysisMode = .digest
  ) {
    guard !messages.isEmpty, !isSubmittingQuickAnalysis else { return }
    guard !model.providerConfigurations.isEmpty else {
      model.workspaceSelection = .providers
      return
    }
    isSubmittingQuickAnalysis = true
    Task {
      _ = await model.enqueueQuickAnalysis(mode: mode, messages: messages)
      isSubmittingQuickAnalysis = false
    }
  }

  private func filterMessages(
    matching match: CryptoAddressMatch,
    from event: MessageEvent,
    scope: AddressMessageScope
  ) {
    model.closeMessageContext()
    switch scope {
    case .current:
      break
    case .group:
      model.workspaceSelection = .group(event.group)
    case .allGroups:
      model.workspaceSelection = .inbox
    }
    model.focusMessages(matching: match)
  }

  private func activityTime(_ health: NotificationMonitorHealth) -> String {
    guard let date = health.lastDatabaseActivityAt else { return "等待新增记录" }
    return "最近活动 \(date.formatted(date: .omitted, time: .standard))"
  }

  private func diagnosticSymbol(_ health: NotificationMonitorHealth) -> String {
    if health.lastError != nil { return "exclamationmark.triangle.fill" }
    switch health.latestActivity {
    case .matchedGroup: return "checkmark.circle.fill"
    case .waitingForNewRecords: return "clock"
    case .nonWeChatNotifications, .payloadDecodeFailed, .groupNotMonitored:
      return "exclamationmark.circle.fill"
    }
  }

  private func diagnosticColor(_ health: NotificationMonitorHealth) -> Color {
    if health.lastError != nil { return .red }
    switch health.latestActivity {
    case .matchedGroup: return .green
    case .waitingForNewRecords: return .secondary
    case .nonWeChatNotifications, .payloadDecodeFailed, .groupNotMonitored:
      return .orange
    }
  }
}

private struct DiagnosticMetric: View {
  let title: String
  let value: Int

  var body: some View {
    HStack(spacing: 4) {
      Text(title)
        .foregroundStyle(.secondary)
      Text("\(value)")
        .font(.caption.monospacedDigit().weight(.medium))
    }
    .fixedSize(horizontal: true, vertical: false)
  }
}

private struct RangeMetric: View {
  let title: String
  let value: String

  init(title: String, value: Int) {
    self.title = title
    self.value = value.formatted()
  }

  init(title: String, value: String) {
    self.title = title
    self.value = value
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value)
        .font(.title3.monospacedDigit().weight(.semibold))
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct InlineRangeMetric: View {
  let title: String
  let value: String

  init(title: String, value: Int) {
    self.title = title
    self.value = value.formatted()
  }

  init(title: String, value: String) {
    self.title = title
    self.value = value
  }

  var body: some View {
    HStack(spacing: 4) {
      Text(title)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.caption.monospacedDigit().weight(.semibold))
    }
    .font(.caption)
    .fixedSize(horizontal: true, vertical: false)
  }
}

private struct MessageFlowDashboard: View {
  @EnvironmentObject private var model: AppModel
  let analytics: MessageFlowAnalytics

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("分时趋势")
          .font(.caption.weight(.semibold))
        Text("每个柱表示固定 \(analytics.bucketGranularity.localizedShortTitle) 桶")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Text("空档只表示本机未采集到通知")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }

      Chart(analytics.timeBuckets, id: \.startDate) { bucket in
        BarMark(
          x: .value("时间", bucket.startDate),
          y: .value("已采集", bucket.capturedCount)
        )
        .foregroundStyle(Color.accentColor.gradient)
      }
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 6)) { value in
          AxisValueLabel {
            if let date = value.as(Date.self) {
              Text(analytics.bucketGranularity.axisLabel(for: date))
            }
          }
        }
      }
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
      }
      .frame(height: 104)

      HStack(alignment: .top, spacing: 16) {
        FlowDistributionColumn(
          title: "群聊贡献",
          items: analytics.groupDistribution.prefix(4).map {
            FlowDistributionItem(
              id: $0.group,
              label: model.displayGroupName($0.group),
              count: $0.capturedCount
            )
          },
          total: analytics.statistics.capturedCount
        )
        Divider()
        FlowDistributionColumn(
          title: "发送者贡献",
          items: analytics.senderDistribution.prefix(4).map {
            FlowDistributionItem(
              id: $0.identityKey,
              label: $0.displayName ?? $0.stableID ?? "未知发送者",
              count: $0.capturedCount
            )
          },
          total: analytics.statistics.capturedCount
        )
        Divider()
        FlowDistributionColumn(
          title: "消息类型",
          items: analytics.messageTypeDistribution.map {
            FlowDistributionItem(
              id: $0.messageType.rawValue,
              label: $0.messageType.localizedFlowTitle,
              count: $0.capturedCount
            )
          },
          total: analytics.statistics.capturedCount
        )
      }
      .frame(minHeight: 82)
    }
  }
}

private struct FlowDistributionItem: Identifiable {
  let id: String
  let label: String
  let count: Int
}

private struct FlowDistributionColumn: View {
  let title: String
  let items: [FlowDistributionItem]
  let total: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption.weight(.semibold))
      ForEach(items) { item in
        HStack(spacing: 6) {
          Text(item.label)
            .lineLimit(1)
          Spacer(minLength: 4)
          Text(item.count.formatted())
            .monospacedDigit()
            .foregroundStyle(.secondary)
          Text(share(item.count))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .frame(width: 34, alignment: .trailing)
        }
        .font(.caption)
      }
      if items.isEmpty {
        Text("暂无数据")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func share(_ count: Int) -> String {
    guard total > 0 else { return "0%" }
    return (Double(count) / Double(total)).formatted(.percent.precision(.fractionLength(0)))
  }
}

private extension FlowAnalyticsBucketGranularity {
  var localizedShortTitle: String {
    switch self {
    case .fiveMinutes: return "5 分钟"
    case .fifteenMinutes: return "15 分钟"
    case .sixtyMinutes: return "60 分钟"
    case .sixHours: return "6 小时"
    case .twentyFourHours: return "24 小时"
    case .sevenDays: return "7 天"
    case .thirtyDays: return "30 天"
    case .ninetyDays: return "90 天"
    case .threeHundredSixtyFiveDays: return "365 天"
    }
  }

  func axisLabel(for date: Date) -> String {
    switch self {
    case .fiveMinutes, .fifteenMinutes, .sixtyMinutes, .sixHours:
      return date.formatted(.dateTime.hour().minute())
    case .twentyFourHours, .sevenDays:
      return date.formatted(.dateTime.month().day())
    case .thirtyDays, .ninetyDays, .threeHundredSixtyFiveDays:
      return date.formatted(.dateTime.year().month())
    }
  }
}

private extension MessageKind {
  var localizedFlowTitle: String {
    switch self {
    case .text: return "文字"
    case .media: return "媒体"
    case .system: return "系统"
    case .unknown: return "未知"
    }
  }
}

private enum AddressMessageScope {
  case current
  case group
  case allGroups
}

private extension CryptoAddressFamily {
  var shortTitle: String {
    switch self {
    case .evm: return "0x"
    case .solana: return "SOL"
    }
  }

  var tintColor: Color {
    switch self {
    case .evm: return .secondary
    case .solana: return .orange
    }
  }
}

private extension CryptoAddressNetwork {
  var shortTitle: String {
    switch self {
    case .ethereum: return "ETH"
    case .base: return "Base"
    case .bsc: return "BSC"
    case .robinhood: return "Robinhood"
    case .solana: return "SOL"
    case .arbitrum: return "Arb"
    case .polygon: return "Polygon"
    case .optimism: return "OP"
    case .avalanche: return "AVAX"
    case .evm: return "待识别"
    }
  }

  var tintColor: Color {
    switch self {
    case .ethereum: return .blue
    case .base: return .indigo
    case .bsc: return .yellow
    case .robinhood: return .green
    case .solana: return .orange
    case .arbitrum: return .cyan
    case .polygon: return .purple
    case .optimism: return .red
    case .avalanche: return .pink
    case .evm: return .secondary
    }
  }

  var gmgnChain: GMGNChain? {
    switch self {
    case .ethereum: return .eth
    case .base: return .base
    case .bsc: return .bsc
    case .robinhood: return .robinhood
    case .solana: return .sol
    case .arbitrum, .polygon, .optimism, .avalanche, .evm: return nil
    }
  }
}

private extension CryptoAddressMatch {
  var shortDisplay: String {
    guard address.count > 18 else { return address }
    return "\(address.prefix(9))…\(address.suffix(7))"
  }
}

private extension WebLinkMatch {
  var shortDisplay: String {
    guard rawValue.count > 42 else { return rawValue }
    return "\(rawValue.prefix(29))…\(rawValue.suffix(10))"
  }
}

private struct MessageRow: View {
  @EnvironmentObject private var model: AppModel
  @State private var isHovering = false
  let event: MessageEvent
  let isCaptured: Bool
  let showsGroup: Bool
  let addresses: [CryptoAddressMatch]
  let webLinks: [WebLinkMatch]
  let isSelectionMode: Bool
  let isSelected: Bool
  let isContextTarget: Bool
  let onToggleSelection: () -> Void
  let onSelectMessage: () -> Void
  let onFilterAddress: (CryptoAddressMatch, AddressMessageScope) -> Void
  let onQueryAddress: (CryptoAddressMatch) -> Void
  let onBuyAddress: (CryptoAddressMatch) -> Void
  let onOpenAddressContext: () -> Void
  let onQuickAnalyze: () -> Void
  let onAdvancedAnalyze: () -> Void
  let onOpenGroup: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 13) {
      if isSelectionMode {
        Button(action: onToggleSelection) {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 17))
            .foregroundStyle(isSelected ? WxFomoTheme.signal : .secondary)
        }
        .buttonStyle(.plain)
        .frame(width: 20, height: 38)
        .help(isSelected ? "取消选择" : "选择消息")
      }

      ZStack {
        Circle()
          .fill(avatarColor.opacity(0.14))
        Text(initial)
          .font(.system(size: 15, weight: .bold, design: .rounded))
          .foregroundStyle(avatarColor)
      }
      .frame(width: 38, height: 38)

      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(event.senderDisplayName ?? "未知发送者")
            .font(.callout.weight(.semibold))
            .foregroundStyle(event.senderDisplayName == nil ? .secondary : .primary)

          if showsGroup {
            Label(model.displayGroupName(event.group), systemImage: "person.3.fill")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }

          if isCaptured {
            Label("重点", systemImage: "scope")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(WxFomoTheme.priority)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(WxFomoTheme.priority.opacity(0.1), in: Capsule())
              .help("命中重点捕捉关键词")
          }

          if isContextTarget {
            Label("原消息", systemImage: "location.fill")
              .font(.caption.weight(.semibold))
              .foregroundStyle(WxFomoTheme.priority)
          }

          Spacer(minLength: 8)
          WxFomoTimeLabel(
            date: event.observedAt,
            style: .prominent,
            alignment: .trailing
          )
          .frame(minWidth: 98, alignment: .trailing)
        }

        Text(event.content)
          .font(.system(size: 14.5))
          .lineSpacing(2)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)

        if !addresses.isEmpty {
          VStack(alignment: .leading, spacing: 5) {
            ForEach(addresses) { match in
              AddressTokenView(
                eventID: event.eventID,
                match: match,
                onOpenContext: onOpenAddressContext,
                onFilter: { scope in onFilterAddress(match, scope) },
                onQuery: { onQueryAddress(match) },
                onBuy: { onBuyAddress(match) }
              )
            }
          }
          .padding(.top, 2)
        }

        if !webLinks.isEmpty {
          VStack(alignment: .leading, spacing: 5) {
            ForEach(webLinks) { match in
              WebLinkTokenView(match: match)
            }
          }
          .padding(.top, addresses.isEmpty ? 2 : 0)
        }

        if !event.attachments.isEmpty {
          AttachmentGallery(attachments: event.attachments)
        } else if event.messageType == .media {
          Label("系统通知只提供了媒体占位，没有可打开的文件", systemImage: "photo.badge.exclamationmark")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 14)
    .background(
      isSelected
        ? WxFomoTheme.signal.opacity(0.085)
        : (isContextTarget
          ? WxFomoTheme.priority.opacity(0.11)
          : (isHovering ? Color.primary.opacity(0.035) : Color.clear))
    )
    .overlay(alignment: .leading) {
      if isContextTarget {
        Rectangle()
          .fill(WxFomoTheme.priority)
          .frame(width: 4)
          .padding(.vertical, 6)
      } else if isCaptured {
        Rectangle()
          .fill(WxFomoTheme.priority)
          .frame(width: 3)
          .padding(.vertical, 10)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      if isSelectionMode { onToggleSelection() }
    }
    .onHover { isHovering = $0 }
    .contextMenu {
      Button("快速摘要此消息") {
        onQuickAnalyze()
      }
      Button("更多 AI 分析…") {
        onAdvancedAnalyze()
      }
      Divider()
      Button(isSelected ? "取消选择" : "选择此消息") {
        if isSelectionMode {
          onToggleSelection()
        } else {
          onSelectMessage()
        }
      }
      Button("复制内容") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(event.content, forType: .string)
      }
      if showsGroup {
        Button("只看此群") {
          onOpenGroup()
        }
      }
      Button("复制真实群名") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(event.group, forType: .string)
      }
      if let sender = event.senderDisplayName, !sender.isEmpty {
        Button("复制发送者") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(sender, forType: .string)
        }
      }
      if !addresses.isEmpty {
        Divider()
        ForEach(addresses) { match in
          Menu("\(match.network.shortTitle) · \(match.shortDisplay)") {
            Button("定位到群聊上下文") { onOpenAddressContext() }
            Button("复制地址") { copyAddress(match) }
            Button("查询 Meme 数据") { onQueryAddress(match) }
            Button("快速买入") { onBuyAddress(match) }
            Divider()
            Button("在当前范围筛选") { onFilterAddress(match, .current) }
            Button("只看此群相关消息") { onFilterAddress(match, .group) }
            Button("在所有群中筛选") { onFilterAddress(match, .allGroups) }
          }
        }
      }
      if !webLinks.isEmpty {
        Divider()
        ForEach(webLinks) { match in
          Menu("LINK · \(match.shortDisplay)") {
            Button("打开链接") { NSWorkspace.shared.open(match.url) }
            Button("复制链接") { copyWebLink(match) }
          }
        }
      }
    }
  }

  private var initial: String {
    guard let sender = event.senderDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
      let first = sender.first
    else { return "?" }
    return String(first).uppercased()
  }

  private var avatarColor: Color {
    let palette: [Color] = [
      WxFomoTheme.signal, .blue, .orange, .pink, .teal, .indigo,
    ]
    let hash = event.senderDisplayName?.unicodeScalars.reduce(0) { $0 + Int($1.value) } ?? 0
    return palette[abs(hash) % palette.count]
  }

  private func copyAddress(_ match: CryptoAddressMatch) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(match.address, forType: .string)
  }


  private func copyWebLink(_ match: WebLinkMatch) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(match.rawValue, forType: .string)
  }
}

private struct AddressTokenView: View {
  @EnvironmentObject private var model: AppModel
  let eventID: String
  let match: CryptoAddressMatch
  let onOpenContext: () -> Void
  let onFilter: (AddressMessageScope) -> Void
  let onQuery: () -> Void
  let onBuy: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      Button {
        onOpenContext()
      } label: {
        HStack(spacing: 8) {
          if let snapshot = displaySnapshot {
            TokenArtworkView(snapshot: snapshot, size: 27, cornerRadius: 5)
          }
          if let chain = resolvedChain {
            TokenChainBadge(chain: chain, compact: true)
          } else {
            Text(match.network.shortTitle)
              .font(.caption2.weight(.bold))
              .foregroundStyle(match.network.tintColor)
          }
          signalIdentity
            .frame(maxWidth: 220, alignment: .leading)
        }
        .padding(.leading, 8)
        .padding(.trailing, 7)
        .frame(height: 34)
      }
      .buttonStyle(.plain)
      .help("定位到这条 CA 的群聊上下文")

      Rectangle()
        .fill(match.network.tintColor.opacity(0.2))
        .frame(width: 1, height: 15)

      Button(action: copyAddress) {
        Image(systemName: "doc.on.doc")
          .font(.caption)
          .frame(width: 27, height: 34)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("复制完整地址")

      Rectangle()
        .fill(match.network.tintColor.opacity(0.2))
        .frame(width: 1, height: 15)

      Button(action: onQuery) {
        HStack(spacing: 4) {
          Image(systemName: "chart.line.uptrend.xyaxis")
          if let marketCapButtonTitle {
            Text(marketCapButtonTitle)
              .font(.caption2.monospacedDigit().weight(.semibold))
          }
        }
        .font(.caption)
        .padding(.horizontal, marketCapButtonTitle == nil ? 0 : 7)
        .frame(minWidth: 27, minHeight: 34)
      }
      .buttonStyle(.plain)
      .foregroundStyle(marketCapButtonTitle == nil ? Color.secondary : WxFomoTheme.signal)
      .help(marketCapButtonTitle == nil ? "查询币名和市值" : "查看当前行情和市值详情")

      Rectangle()
        .fill(match.network.tintColor.opacity(0.2))
        .frame(width: 1, height: 15)

      Button(action: onBuy) {
        Image(systemName: "bolt.horizontal.circle.fill")
          .font(.caption)
          .frame(width: 30, height: 34)
      }
      .buttonStyle(.plain)
      .foregroundStyle(WxFomoTheme.priority)
      .help("打开快速买入；点击立即买入后直接提交")

      if let gmgnURL {
        Rectangle()
          .fill(match.network.tintColor.opacity(0.2))
          .frame(width: 1, height: 15)

        Link(destination: gmgnURL) {
          Label("GMGN", systemImage: "waveform.path.ecg")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .frame(minHeight: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(WxFomoTheme.signal)
        .help("在浏览器打开 GMGN 代币页面")
      }

      if let fomoURL {
        Rectangle()
          .fill(match.network.tintColor.opacity(0.2))
          .frame(width: 1, height: 15)

        Link(destination: fomoURL) {
          Label("Fomo", systemImage: "bolt.fill")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .frame(minHeight: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.orange)
        .help("在浏览器打开 Fomo 代币页面")
      }
    }
    .fixedSize(horizontal: true, vertical: false)
    .background(
      match.network.tintColor.opacity(0.075),
      in: RoundedRectangle(cornerRadius: 5)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 5)
        .stroke(match.network.tintColor.opacity(0.22))
    }
    .contextMenu {
      Button("定位到群聊上下文", action: onOpenContext)
      Button("复制完整地址", action: copyAddress)
      Button("查看币种与市值", action: onQuery)
      Button("快速买入", action: onBuy)
      if let gmgnURL {
        Button("在 GMGN 打开") { NSWorkspace.shared.open(gmgnURL) }
      }
      if let fomoURL {
        Button("在 Fomo 打开") { NSWorkspace.shared.open(fomoURL) }
      }
      if enrichment?.state == .failed {
        Button("重新识别") {
          model.retryCASignal(eventID: eventID, match: match)
        }
      }
      Divider()
      Button("在当前范围筛选") { onFilter(.current) }
      Button("只看此群相关消息") { onFilter(.group) }
      Button("在所有群中筛选") { onFilter(.allGroups) }
    }
  }

  @ViewBuilder
  private var signalIdentity: some View {
    if let snapshot = displaySnapshot {
      VStack(alignment: .leading, spacing: 1) {
        Text(tokenTitle(snapshot))
          .font(.caption.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
        Text("\(snapshotTimeLabel) \(compactUSD(snapshot.marketCapUSD)) · \(match.shortDisplay)")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    } else if enrichment?.state == .pending || poolItem?.state == .pending {
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 4) {
          ProgressView()
            .controlSize(.mini)
          Text("正在识别币名与市值")
            .font(.caption.weight(.medium))
        }
        Text(match.shortDisplay)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
      }
    } else if enrichment?.state == .failed {
      VStack(alignment: .leading, spacing: 1) {
        Label("未识别，可重试", systemImage: "exclamationmark.triangle")
          .font(.caption.weight(.medium))
          .foregroundStyle(.orange)
        Text(match.shortDisplay)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
      }
    } else {
      Text(match.shortDisplay)
        .font(.caption.monospaced())
        .foregroundStyle(.primary)
    }
  }

  private var enrichment: CASignalEnrichment? {
    model.caSignalEnrichment(eventID: eventID, match: match)
  }

  private var poolItem: CAWatchPoolItem? {
    model.caWatchPoolItem(for: match)
  }

  private var displaySnapshot: CATokenMarketSnapshot? {
    enrichment?.snapshot ?? poolItem?.currentSnapshot
  }

  private var resolvedChain: GMGNChain? {
    displaySnapshot?.chain ?? match.network.gmgnChain
  }

  private var gmgnURL: URL? {
    guard let chain = resolvedChain else { return nil }
    return TokenExternalLinks.gmgn(chain: chain, address: match.normalizedAddress)
  }

  private var fomoURL: URL? {
    guard let chain = resolvedChain else { return nil }
    return TokenExternalLinks.fomo(chain: chain, address: match.normalizedAddress)
  }

  private var snapshotTimeLabel: String {
    enrichment?.snapshot == nil ? "现" : "提示"
  }

  private var marketCapButtonTitle: String? {
    guard let value = poolItem?.currentSnapshot?.marketCapUSD ?? enrichment?.snapshot?.marketCapUSD
    else { return nil }
    return compactUSD(value)
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

  private func compactUSD(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "市值未返回" }
    let magnitude = abs(value)
    if magnitude >= 1_000_000_000 {
      return "$" + (value / 1_000_000_000).formatted(
        .number.precision(.fractionLength(0...2))
      ) + "B"
    }
    if magnitude >= 1_000_000 {
      return "$" + (value / 1_000_000).formatted(
        .number.precision(.fractionLength(0...2))
      ) + "M"
    }
    if magnitude >= 1_000 {
      return "$" + (value / 1_000).formatted(
        .number.precision(.fractionLength(0...1))
      ) + "K"
    }
    return value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
  }

  private func copyAddress() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(match.address, forType: .string)
  }
}

private struct WebLinkTokenView: View {
  let match: WebLinkMatch

  var body: some View {
    HStack(spacing: 0) {
      Button(action: openLink) {
        HStack(spacing: 7) {
          Text("LINK")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.teal)
          Text(match.shortDisplay)
            .font(.caption.monospaced())
            .foregroundStyle(.primary)
          Image(systemName: "arrow.up.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 8)
        .padding(.trailing, 7)
        .frame(height: 26)
      }
      .buttonStyle(.plain)
      .help("在默认浏览器中打开")

      Rectangle()
        .fill(Color.teal.opacity(0.2))
        .frame(width: 1, height: 15)

      Button(action: copyLink) {
        Image(systemName: "doc.on.doc")
          .font(.caption)
          .frame(width: 27, height: 26)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("复制完整链接")
    }
    .fixedSize(horizontal: true, vertical: false)
    .background(Color.teal.opacity(0.075), in: RoundedRectangle(cornerRadius: 5))
    .overlay {
      RoundedRectangle(cornerRadius: 5)
        .stroke(Color.teal.opacity(0.22))
    }
    .contextMenu {
      Button("打开链接", action: openLink)
      Button("复制完整链接", action: copyLink)
    }
  }

  private func openLink() {
    NSWorkspace.shared.open(match.url)
  }

  private func copyLink() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(match.rawValue, forType: .string)
  }
}

private struct AttachmentGallery: View {
  let attachments: [MessageAttachment]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
        AttachmentPreview(attachment: attachment)
      }
    }
    .padding(.top, 3)
  }
}

private struct AttachmentPreview: View {
  let attachment: MessageAttachment
  @State private var image: NSImage?
  @State private var imageLoadFailed = false

  var body: some View {
    Group {
      if attachment.kind == .image {
        if let image {
          Button(action: openAttachment) {
            Image(nsImage: image)
              .resizable()
              .scaledToFit()
              .frame(maxWidth: 360, maxHeight: 240, alignment: .leading)
              .clipShape(RoundedRectangle(cornerRadius: 6))
              .overlay(alignment: .topTrailing) {
                Image(systemName: "arrow.up.right.square.fill")
                  .font(.system(size: 17))
                  .symbolRenderingMode(.palette)
                  .foregroundStyle(.white, .black.opacity(0.55))
                  .padding(7)
              }
          }
          .buttonStyle(.plain)
          .help("打开图片")
        } else if !imageLoadFailed {
          ProgressView()
            .controlSize(.small)
            .frame(width: 72, height: 48)
            .task(id: attachment.fileURL) {
              await loadImage()
            }
        } else {
          attachmentFallback
        }
      } else {
        attachmentFallback
      }
    }
  }

  private var attachmentFallback: some View {
    Button(action: openAttachment) {
      Label(attachmentTitle, systemImage: attachmentSymbol)
        .lineLimit(1)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .disabled(!FileManager.default.fileExists(atPath: attachment.fileURL.path))
    .help(attachmentAvailable ? "打开附件" : "通知附件文件已经不可用")
  }

  private func loadImage() async {
    guard FileManager.default.fileExists(atPath: attachment.fileURL.path) else {
      imageLoadFailed = true
      return
    }
    let data = await Task.detached(priority: .utility) {
      try? Data(contentsOf: attachment.fileURL)
    }.value
    guard let data, let decoded = NSImage(data: data) else {
      imageLoadFailed = true
      return
    }
    image = decoded
  }

  private var attachmentAvailable: Bool {
    FileManager.default.fileExists(atPath: attachment.fileURL.path)
  }

  private var attachmentTitle: String {
    let name = attachment.fileURL.lastPathComponent
    if !attachmentAvailable { return name.isEmpty ? "附件不可用" : "\(name)（不可用）" }
    return name.isEmpty ? "打开附件" : name
  }

  private var attachmentSymbol: String {
    switch attachment.kind {
    case .image: return "photo"
    case .video: return "video"
    case .audio: return "waveform"
    case .file, .unknown: return "paperclip"
    }
  }

  private func openAttachment() {
    guard attachmentAvailable else { return }
    NSWorkspace.shared.open(attachment.fileURL)
  }
}

private struct AddressFilterTabs: View {
  @EnvironmentObject private var model: AppModel
  let compact: Bool

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 2) {
          ForEach(AppModel.AddressFilter.allCases) { filter in
            tabButton(filter)
              .id(filter)
          }
        }
        .padding(.horizontal, 2)
      }
      .frame(height: 30)
      .onAppear {
        proxy.scrollTo(model.addressFilter, anchor: .center)
      }
      .onChange(of: model.addressFilter) { _, filter in
        withAnimation(.easeOut(duration: 0.18)) {
          proxy.scrollTo(filter, anchor: .center)
        }
      }
    }
    .frame(maxWidth: compact ? 520 : .infinity, alignment: .leading)
    .help("按地址所在网络或 HTTP/HTTPS 链接筛选")
  }

  @ViewBuilder
  private func tabButton(_ filter: AppModel.AddressFilter) -> some View {
    let isSelected = model.addressFilter == filter
    Button {
      model.setAddressFilter(filter)
    } label: {
      HStack(spacing: 4) {
        Image(systemName: filter.systemImage)
          .imageScale(.small)
        Text(filter.title)
      }
      .font(.caption.weight(isSelected ? .semibold : .regular))
      .foregroundStyle(isSelected ? WxFomoTheme.signal : .secondary)
      .padding(.horizontal, 8)
      .frame(height: 28)
      .background(
        isSelected ? WxFomoTheme.signal.opacity(0.11) : Color.clear,
        in: RoundedRectangle(cornerRadius: 5)
      )
      .overlay(alignment: .bottom) {
        Capsule()
          .fill(isSelected ? WxFomoTheme.signal : Color.clear)
          .frame(height: 2)
          .padding(.horizontal, 5)
      }
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .help(filter.title)
  }
}

private struct FilterPanel: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("筛选与捕捉")
          .font(.headline)
        Spacer()
        Button("重置筛选", action: model.resetFilters)
          .disabled(model.activeFilterCount == 0)
      }

      Picker("消息类型", selection: $model.kindFilter) {
        ForEach(AppModel.KindFilter.allCases) { kind in
          Text(kind.title).tag(kind)
        }
      }
      .pickerStyle(.segmented)

      VStack(alignment: .leading, spacing: 6) {
        Text("地址与链接")
          .font(.caption)
          .foregroundStyle(.secondary)
        AddressFilterTabs(compact: false)
        Text("SOL 会校验 Base58 长度与上下文；链接只匹配明确的 HTTP/HTTPS URL。")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("包含关键词")
          .font(.caption)
          .foregroundStyle(.secondary)
        TextField("多个词用逗号分隔", text: $model.includeKeywords)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("排除关键词")
          .font(.caption)
          .foregroundStyle(.secondary)
        TextField("多个词用逗号分隔", text: $model.excludeKeywords)
      }

      Toggle("仅显示 @ 我的通知", isOn: $model.onlyMentions)
      Toggle("隐藏未知发送者", isOn: $model.onlyKnownSenders)

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        Label("重点捕捉关键词", systemImage: "scope")
          .font(.callout.weight(.medium))
        TextField("命中后进入重点捕捉", text: $model.captureKeywords)
        Text("多个词用逗号分隔，规则保存在本机。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .frame(width: 340)
  }
}
