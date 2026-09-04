import AppKit
import SwiftUI
import WxFomoCore

struct AnalysisWorkspaceView: View {
  @EnvironmentObject private var model: AppModel
  @State private var selectedJobID: String?

  var body: some View {
    WorkspacePage(title: "分析记录", subtitle: "选择群聊和时间区间，一键生成可追溯的 AI 总结") {
      VStack(spacing: 0) {
        AnalysisScopeComposer {
          selectedJobID = model.analysisJobs.first?.jobID
        }
        .environmentObject(model)

        Divider()

        if model.analysisJobs.isEmpty {
          ContentUnavailableView {
            Label("还没有分析记录", systemImage: "sparkles.rectangle.stack")
          } description: {
            Text("在上方选择消息范围，然后点击“生成总结”。")
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          HSplitView {
            AnalysisJobList(selectedJobID: $selectedJobID)
              .environmentObject(model)
              .frame(minWidth: 225, idealWidth: 255, maxWidth: 310)

            AnalysisJobDetail(job: selectedJob)
              .environmentObject(model)
              .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      }
      .onAppear(perform: ensureSelection)
      .onChange(of: model.analysisJobs) { ensureSelection() }
      .onChange(of: selectedJobID) { selectResultForCurrentJob() }
    }
  }

  private var selectedJob: AIAnalysisJob? {
    guard let selectedJobID else { return nil }
    return model.analysisJobs.first { $0.jobID == selectedJobID }
  }

  private func ensureSelection() {
    if let selectedJobID, model.analysisJobs.contains(where: { $0.jobID == selectedJobID }) {
      selectResultForCurrentJob()
      return
    }

    if let result = model.selectedAnalysisResult,
      let matchingJob = model.analysisJobs.first(where: { $0.jobID == result.jobID })
    {
      selectedJobID = matchingJob.jobID
    } else {
      selectedJobID = model.analysisJobs.first?.jobID
    }
    selectResultForCurrentJob()
  }

  private func selectResultForCurrentJob() {
    guard let selectedJobID,
      let result = model.analysisResults.first(where: { $0.jobID == selectedJobID })
    else { return }
    if model.selectedAnalysisID != result.result.analysisID {
      model.selectAnalysis(result.result.analysisID)
    }
  }
}

private enum AnalysisRangePreset: String, CaseIterable, Identifiable {
  case last30Minutes
  case last2Hours
  case last6Hours
  case today
  case custom

  var id: String { rawValue }

  var title: String {
    switch self {
    case .last30Minutes: return "30 分钟"
    case .last2Hours: return "2 小时"
    case .last6Hours: return "6 小时"
    case .today: return "今天"
    case .custom: return "自定义"
    }
  }
}

private struct AnalysisScopeComposer: View {
  @EnvironmentObject private var model: AppModel
  let onSubmitted: () -> Void

  @State private var selectedMode: AIAnalysisMode = .digest
  @State private var selectedGroups: Set<String> = []
  @State private var rangePreset: AnalysisRangePreset = .last30Minutes
  @State private var rangeAnchor = Date()
  @State private var customRangeStart = Date().addingTimeInterval(-2 * 60 * 60)
  @State private var customRangeEnd = Date()
  @State private var selectedProviderID: String?
  @State private var statistics: MessageRangeStatistics?
  @State private var previewError: String?
  @State private var isLoadingPreview = false
  @State private var isSubmitting = false

  private let quickModes: [AIAnalysisMode] = [
    .digest, .importantInformation, .actionItems, .risksAndOpportunities,
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      composerHeader
      selectionControls

      if rangePreset == .custom {
        customRangeControls
      }

      scopeSummary

      if let previewError {
        Label(previewError, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(2)
      } else if let error = model.workspaceStoreError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(2)
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
    .onAppear {
      synchronizeGroups()
      ensureProviderSelection()
    }
    .onChange(of: model.groups) { synchronizeGroups() }
    .onChange(of: model.providerConfigurations) { ensureProviderSelection() }
    .task(id: previewKey) {
      await refreshPreview()
    }
  }

  private var composerHeader: some View {
    HStack(spacing: 12) {
      Label("新建 AI 总结", systemImage: "sparkles.rectangle.stack.fill")
        .font(.headline)
        .foregroundStyle(WxFomoTheme.signal)

      if isLoadingPreview {
        ProgressView()
          .controlSize(.small)
      }

      Spacer(minLength: 12)

      if model.providerConfigurations.isEmpty {
        Button {
          model.workspaceSelection = .providers
        } label: {
          Label("配置 AI 服务", systemImage: "key")
        }
      } else {
        Picker("AI 服务", selection: $selectedProviderID) {
          ForEach(model.providerConfigurations) { configuration in
            Text("\(configuration.displayName) · \(configuration.model)")
              .tag(Optional(configuration.configurationID))
          }
        }
        .labelsHidden()
        .frame(width: 210)
      }

      Button {
        submit()
      } label: {
        if isSubmitting {
          ProgressView()
            .controlSize(.small)
            .frame(width: 96)
        } else {
          Label("生成总结", systemImage: "wand.and.sparkles")
            .frame(width: 96)
        }
      }
      .buttonStyle(.borderedProminent)
      .tint(WxFomoTheme.signal)
      .disabled(!canSubmit)
      .help(generateButtonHelp)
    }
  }

  private var selectionControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Text("总结类型")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 58, alignment: .leading)
        HStack(spacing: 6) {
          ForEach(quickModes, id: \.self) { mode in
            analysisModeButton(mode)
          }
        }
        Spacer(minLength: 0)
      }

      HStack(spacing: 10) {
        Text("群聊范围")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 58, alignment: .leading)
        groupMenu
        Divider()
          .frame(height: 22)
        HStack(spacing: 6) {
          Text("时间区间")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Button {
            rangeAnchor = Date()
            if rangePreset == .custom {
              customRangeEnd = rangeAnchor
            }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("以当前时间重新计算范围")
        }
        Picker("时间区间", selection: $rangePreset) {
          ForEach(AnalysisRangePreset.allCases) { preset in
            Text(preset.title).tag(preset)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(minWidth: 280, maxWidth: 350)
        Spacer(minLength: 0)
      }
    }
  }

  private var groupMenu: some View {
    Menu {
      Button {
        selectedGroups = Set(model.groups)
      } label: {
        Label(
          "全部群聊",
          systemImage: allGroupsSelected ? "checkmark.circle.fill" : "circle"
        )
      }
      Button {
        selectedGroups.removeAll()
      } label: {
        Label("清除选择", systemImage: "xmark.circle")
      }
      Divider()
      ForEach(Array(model.groups.enumerated()), id: \.element) { index, group in
        Button {
          toggleGroup(group)
        } label: {
          Label(
            groupLabel(group, index: index),
            systemImage: selectedGroups.contains(group) ? "checkmark.circle.fill" : "circle"
          )
        }
      }
    } label: {
      Label(groupSelectionTitle, systemImage: groupSelectionSymbol)
        .lineLimit(1)
        .frame(width: 150, alignment: .leading)
    }
    .menuStyle(.borderlessButton)
  }

  private var customRangeControls: some View {
    HStack(spacing: 10) {
      Label("自定义", systemImage: "calendar.badge.clock")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      DatePicker(
        "开始",
        selection: $customRangeStart,
        displayedComponents: [.date, .hourAndMinute]
      )
      DatePicker(
        "结束",
        selection: $customRangeEnd,
        displayedComponents: [.date, .hourAndMinute]
      )
      Spacer(minLength: 0)
    }
  }

  private var scopeSummary: some View {
    HStack(spacing: 16) {
      Label(groupCountLabel, systemImage: "person.3")
      Label(messageCountLabel, systemImage: "text.bubble")
      Label(activeRangeTitle, systemImage: "clock")
      Spacer(minLength: 8)
      Text("提交时冻结当前范围，之后到达的消息不会混入本次结果")
        .lineLimit(1)
        .foregroundStyle(.tertiary)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private var allGroupsSelected: Bool {
    !model.groups.isEmpty && selectedGroups == Set(model.groups)
  }

  private var groupSelectionTitle: String {
    if selectedGroups.isEmpty { return "选择群聊" }
    if allGroupsSelected { return "全部 \(selectedGroups.count) 个群" }
    if selectedGroups.count == 1, let group = selectedGroups.first {
      return model.displayGroupName(group)
    }
    return "已选 \(selectedGroups.count) 个群"
  }

  private var groupSelectionSymbol: String {
    selectedGroups.count == 1 ? "person.2" : "person.3"
  }

  private var groupCountLabel: String {
    selectedGroups.isEmpty ? "未选择群聊" : "\(selectedGroups.count) 个群"
  }

  private var messageCountLabel: String {
    if isLoadingPreview { return "正在统计消息" }
    guard let statistics else { return "消息数未知" }
    return "\(statistics.capturedCount.formatted()) 条已采集消息"
  }

  private var activeRange: MessageDateRange {
    switch rangePreset {
    case .last30Minutes:
      return MessageDateRange(start: rangeAnchor.addingTimeInterval(-30 * 60), end: rangeAnchor)
    case .last2Hours:
      return MessageDateRange(start: rangeAnchor.addingTimeInterval(-2 * 60 * 60), end: rangeAnchor)
    case .last6Hours:
      return MessageDateRange(start: rangeAnchor.addingTimeInterval(-6 * 60 * 60), end: rangeAnchor)
    case .today:
      return MessageDateRange(start: Calendar.current.startOfDay(for: rangeAnchor), end: rangeAnchor)
    case .custom:
      return MessageDateRange(start: customRangeStart, end: customRangeEnd).normalized
    }
  }

  private var activeRangeTitle: String {
    switch rangePreset {
    case .last30Minutes, .last2Hours, .last6Hours, .today:
      return rangePreset.title
    case .custom:
      let range = activeRange
      return "\(range.start.formatted(.dateTime.month().day().hour().minute())) - \(range.end.formatted(.dateTime.month().day().hour().minute()))"
    }
  }

  private var previewKey: String {
    let groupsKey = selectedGroups.sorted().joined(separator: "|")
    let range = activeRange
    return "\(groupsKey)#\(range.start.timeIntervalSince1970)#\(range.end.timeIntervalSince1970)"
  }

  private var canSubmit: Bool {
    guard !isSubmitting,
      selectedProviderID != nil,
      !selectedGroups.isEmpty,
      let statistics
    else { return false }
    return statistics.capturedCount > 0
      && statistics.capturedCount <= AIAnalysisRequest.maximumMessageCount
  }

  private var generateButtonHelp: String {
    if model.providerConfigurations.isEmpty { return "请先配置 AI 服务" }
    if selectedGroups.isEmpty { return "请至少选择一个群聊" }
    guard let statistics else { return "正在统计所选范围" }
    if statistics.capturedCount == 0 { return "所选范围没有已采集消息" }
    if statistics.capturedCount > AIAnalysisRequest.maximumMessageCount {
      return "消息过多，请缩短时间区间"
    }
    return "冻结并总结所选范围的 \(statistics.capturedCount) 条消息"
  }

  private func analysisModeButton(_ mode: AIAnalysisMode) -> some View {
    let isSelected = selectedMode == mode
    return Button {
      selectedMode = mode
    } label: {
      VStack(spacing: 3) {
        Image(systemName: mode.systemImage)
          .font(.system(size: 14, weight: .semibold))
        Text(mode.localizedTitle)
          .font(.caption2)
          .lineLimit(1)
      }
      .frame(width: 70, height: 42)
      .foregroundStyle(isSelected ? Color.white : Color.primary)
      .background(isSelected ? WxFomoTheme.signal : Color(nsColor: .windowBackgroundColor))
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .stroke(isSelected ? WxFomoTheme.signal : Color(nsColor: .separatorColor))
      }
      .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(mode.localizedTitle)
  }

  private func groupLabel(_ group: String, index: Int) -> String {
    model.redactsGroupNames ? "群 \(index + 1)" : group
  }

  private func toggleGroup(_ group: String) {
    if selectedGroups.contains(group) {
      selectedGroups.remove(group)
    } else {
      selectedGroups.insert(group)
    }
  }

  private func synchronizeGroups() {
    let availableGroups = Set(model.groups)
    selectedGroups.formIntersection(availableGroups)
    if selectedGroups.isEmpty, !availableGroups.isEmpty {
      selectedGroups = availableGroups
    }
  }

  private func ensureProviderSelection() {
    if let selectedProviderID,
      model.providerConfigurations.contains(where: {
        $0.configurationID == selectedProviderID
      })
    {
      return
    }
    if let defaultProviderID = model.defaultProviderID,
      model.providerConfigurations.contains(where: {
        $0.configurationID == defaultProviderID
      })
    {
      selectedProviderID = defaultProviderID
    } else {
      selectedProviderID = model.providerConfigurations.first?.configurationID
    }
  }

  private func refreshPreview() async {
    guard !selectedGroups.isEmpty else {
      statistics = nil
      previewError = nil
      return
    }
    isLoadingPreview = true
    defer { isLoadingPreview = false }
    do {
      let loaded = try await model.analysisStatistics(
        groups: selectedGroups,
        range: activeRange
      )
      guard !Task.isCancelled else { return }
      statistics = loaded
      previewError = nil
    } catch {
      guard !Task.isCancelled else { return }
      statistics = nil
      previewError = error.localizedDescription
    }
  }

  private func submit() {
    guard canSubmit else { return }
    isSubmitting = true
    let submittedGroups = selectedGroups
    let submittedRange = activeRange
    Task {
      let submitted = await model.enqueueScopedAnalysis(
        mode: selectedMode,
        providerID: selectedProviderID,
        groups: submittedGroups,
        range: submittedRange
      )
      isSubmitting = false
      if submitted {
        onSubmitted()
      }
    }
  }
}

private struct AnalysisJobList: View {
  @EnvironmentObject private var model: AppModel
  @Binding var selectedJobID: String?
  @State private var currentPage = 1

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("任务")
          .font(.headline)
        Spacer()
        if model.pendingAnalysisJobCount > 0 {
          Text("处理中 \(model.pendingAnalysisJobCount)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        } else {
          Text("共 \(model.analysisJobs.count)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 11)
      Divider()

      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(pagedJobs) { job in
            Button {
              selectedJobID = job.jobID
            } label: {
              AnalysisJobRow(job: job, isSelected: selectedJobID == job.jobID)
            }
            .buttonStyle(.plain)
            .contextMenu {
              Button("查看详情") {
                selectedJobID = job.jobID
              }
              if model.analysisResults.contains(where: { $0.jobID == job.jobID }) {
                Button("复制摘要") {
                  copySummary(for: job)
                }
              }
              if !job.state.isTerminal {
                Divider()
                Button("取消任务", role: .destructive) {
                  model.cancelAnalysisJob(job)
                }
              }
            }
            Divider()
              .padding(.leading, 42)
          }
        }
      }
      PaginationBar(totalCount: model.analysisJobs.count, currentPage: $currentPage)
    }
    .onAppear(perform: revealSelectedJob)
    .onChange(of: selectedJobID) { revealSelectedJob() }
  }

  private var pagedJobs: [AIAnalysisJob] {
    model.analysisJobs.pageItems(page: currentPage)
  }

  private func revealSelectedJob() {
    guard let selectedJobID,
      let index = model.analysisJobs.firstIndex(where: { $0.jobID == selectedJobID })
    else { return }
    currentPage = index / WorkspacePagination.pageSize + 1
  }

  private func copySummary(for job: AIAnalysisJob) {
    guard let summary = model.analysisResults.first(where: { $0.jobID == job.jobID })?
      .result.summary
    else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(summary, forType: .string)
  }
}

private struct AnalysisJobRow: View {
  @EnvironmentObject private var model: AppModel
  let job: AIAnalysisJob
  let isSelected: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: job.state.workspaceSymbol)
        .foregroundStyle(job.state.workspaceColor)
        .frame(width: 18, height: 20)

      VStack(alignment: .leading, spacing: 4) {
        Text(job.mode.localizedTitle)
          .font(.callout.weight(.medium))
          .lineLimit(1)
        HStack(spacing: 5) {
          Text(job.state.workspaceTitle)
            .foregroundStyle(job.state.workspaceColor)
          Text("·")
          Text(providerName)
            .lineLimit(1)
        }
        .font(.caption)
        if let range = model.analysisRanges[job.frozenRangeID] {
          HStack(spacing: 5) {
            Label(scopeTitle(range), systemImage: "person.3")
              .lineLimit(1)
            Text("·")
            Text("\(range.eventIDs.count) 条")
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
          Text(rangeTitle(range))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        } else {
          Text(job.createdAt, format: .dateTime.month().day().hour().minute())
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    .contentShape(Rectangle())
  }

  private var providerName: String {
    model.providerConfigurations.first { $0.configurationID == job.providerID }?.displayName
      ?? "服务已移除"
  }

  private func scopeTitle(_ range: FrozenMessageRange) -> String {
    if range.scope.groups.count == 1, let group = range.scope.groups.first {
      return model.displayGroupName(group)
    }
    if range.scope.groups.isEmpty { return "全部群" }
    return "\(range.scope.groups.count) 个群"
  }

  private func rangeTitle(_ range: FrozenMessageRange) -> String {
    let start = range.scope.startDate ?? range.earliestObservedAt
    let end = range.scope.endDate ?? range.latestObservedAt
    guard let start, let end else {
      return job.createdAt.formatted(.dateTime.month().day().hour().minute())
    }
    return "\(start.formatted(.dateTime.month().day().hour().minute())) - \(end.formatted(.dateTime.month().day().hour().minute()))"
  }
}

private struct AnalysisJobDetail: View {
  @EnvironmentObject private var model: AppModel
  let job: AIAnalysisJob?

  var body: some View {
    Group {
      if let job {
        VStack(spacing: 0) {
          jobHeader(job)
          Divider()
          detailBody(job)
        }
      } else {
        ContentUnavailableView("选择一个任务", systemImage: "sidebar.left")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private func jobHeader(_ job: AIAnalysisJob) -> some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 5) {
        Text(job.mode.localizedTitle)
          .font(.headline)
        HStack(spacing: 7) {
          Label(job.state.workspaceTitle, systemImage: job.state.workspaceSymbol)
            .foregroundStyle(job.state.workspaceColor)
          Text("·")
            .foregroundStyle(.tertiary)
          Text(job.updatedAt, format: .dateTime.year().month().day().hour().minute())
            .foregroundStyle(.secondary)
        }
        .font(.caption)
      }
      Spacer(minLength: 8)
      if !job.state.isTerminal {
        Button(role: .destructive) {
          model.cancelAnalysisJob(job)
        } label: {
          Label("取消任务", systemImage: "xmark.circle")
        }
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
  }

  @ViewBuilder
  private func detailBody(_ job: AIAnalysisJob) -> some View {
    if let stored = model.analysisResults.first(where: { $0.jobID == job.jobID }) {
      AnalysisResultDetail(
        stored: stored,
        providerName: model.providerConfigurations.first {
          $0.configurationID == stored.result.provenance.providerConfigurationID
        }?.displayName ?? stored.result.provenance.providerKind.localizedTitle,
        sourceMessages: model.selectedAnalysisSourceMessages,
        sourceMessageRevision: model.selectedAnalysisSourceRevision,
        redactsGroupNames: model.redactsGroupNames,
        onOpenMeme: model.openMemeMode(for:)
      )
      .equatable()
    } else {
      AnalysisPendingDetail(job: job)
        .environmentObject(model)
    }
  }
}

private struct AnalysisPendingDetail: View {
  @EnvironmentObject private var model: AppModel
  let job: AIAnalysisJob

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .top, spacing: 12) {
          if job.state == .running {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: job.state.workspaceSymbol)
              .foregroundStyle(job.state.workspaceColor)
          }
          VStack(alignment: .leading, spacing: 4) {
            Text(statusHeadline)
              .font(.headline)
            Text(statusExplanation)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }

        Divider()
        metadataRow("AI 服务", value: providerName)
        metadataRow("尝试次数", value: "\(job.attempt) / \(job.maximumAttempts)")
        if let nextAttemptAt = job.nextAttemptAt, job.state == .retryWait {
          metadataRow(
            "下次重试",
            value: nextAttemptAt.formatted(.dateTime.month().day().hour().minute().second())
          )
        }
        if let customInstructions = job.customInstructions, !customInstructions.isEmpty {
          Divider()
          Text("自定义要求")
            .font(.headline)
          Text(customInstructions)
            .textSelection(.enabled)
        }
        if let lastError = job.lastError, !lastError.isEmpty {
          Divider()
          Label("任务诊断", systemImage: "exclamationmark.triangle")
            .font(.headline)
            .foregroundStyle(job.state == .failed ? .red : .orange)
          Text(lastError)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }

        Divider()
        Label(
          "任务只使用创建时冻结的本地已采集消息，不代表企业微信群完整消息流。",
          systemImage: "exclamationmark.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var statusHeadline: String {
    switch job.state {
    case .pending: return "任务正在排队"
    case .running: return "AI 正在分析"
    case .retryWait: return "任务将在稍后重试"
    case .failed: return "分析失败"
    case .cancelled: return "任务已取消"
    case .succeeded: return "结果正在写入"
    }
  }

  private var statusExplanation: String {
    switch job.state {
    case .pending: return "任务已持久化，可以关闭应用后再回来查看。"
    case .running: return "完成后会在这里显示摘要、主题、结论和来源。"
    case .retryWait: return "上次调用未成功，队列会按计划继续尝试。"
    case .failed: return "请根据诊断检查服务配置、网络或模型能力。"
    case .cancelled: return "这个任务不会继续执行。"
    case .succeeded: return "任务已完成，正在刷新持久化结果。"
    }
  }

  private var providerName: String {
    model.providerConfigurations.first { $0.configurationID == job.providerID }
      .map { "\($0.displayName) · \($0.model)" } ?? "服务已移除"
  }

  private func metadataRow(_ title: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(title)
        .foregroundStyle(.secondary)
        .frame(width: 72, alignment: .leading)
      Text(value)
        .textSelection(.enabled)
      Spacer(minLength: 0)
    }
    .font(.callout)
  }
}

private struct AnalysisResultDetail: View, Equatable {
  let stored: StoredAIAnalysisResult
  let providerName: String
  let sourceMessages: [String: MessageEvent]
  let sourceMessageRevision: Int
  let redactsGroupNames: Bool
  let onOpenMeme: (AIAnalysisCryptoAddress) -> Void

  private var result: AIAnalysisResult { stored.result }

  // Keep background message updates from deep-comparing every source body.
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.stored.id == rhs.stored.id
      && lhs.stored.updatedAt == rhs.stored.updatedAt
      && lhs.providerName == rhs.providerName
      && lhs.sourceMessageRevision == rhs.sourceMessageRevision
      && lhs.redactsGroupNames == rhs.redactsGroupNames
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        Label(
          "基于冻结的 \(result.provenance.sourceMessageIDs.count) 条本地已采集消息；不是整个时间区间，也不代表企业微信群完整信息流。",
          systemImage: "exclamationmark.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        analysisSection("摘要", symbol: "text.alignleft") {
          Text(result.summary)
            .font(.body)
            .textSelection(.enabled)
          AnalysisSourceLinks(
            sourceIDs: result.summarySourceMessageIDs,
            sourceMessages: sourceMessages,
            redactsGroupNames: redactsGroupNames
          )
        }

        if !result.topics.isEmpty {
          analysisSection("主题", symbol: "square.stack.3d.up") {
            ForEach(Array(result.topics.enumerated()), id: \.element.id) { index, topic in
              if index > 0 { Divider() }
              VStack(alignment: .leading, spacing: 6) {
                Text(topic.title)
                  .font(.callout.weight(.semibold))
                Text(topic.summary)
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
                AnalysisSourceLinks(
                  sourceIDs: topic.sourceMessageIDs,
                  sourceMessages: sourceMessages,
                  redactsGroupNames: redactsGroupNames
                )
              }
              .padding(.vertical, 2)
            }
          }
        }

        if !result.cryptoAddresses.isEmpty {
          analysisSection("链上地址", symbol: "link") {
            Text("地址格式由本地规则识别；0x 地址的网络和币名使用 DexScreener 富化，未富化时显示待识别；角色只按消息上下文提示。")
              .font(.caption)
              .foregroundStyle(.secondary)
            ForEach(Array(result.cryptoAddresses.enumerated()), id: \.element.id) {
              index, address in
              if index > 0 { Divider() }
              AnalysisCryptoAddressRow(
                address: address,
                sourceMessages: sourceMessages,
                redactsGroupNames: redactsGroupNames,
                onOpenMeme: onOpenMeme
              )
            }
          }
        }

        if !result.findings.isEmpty {
          analysisSection("发现", symbol: "scope") {
            ForEach(Array(result.findings.enumerated()), id: \.element.id) { index, finding in
              if index > 0 { Divider() }
              AnalysisFindingRow(
                finding: finding,
                sourceMessages: sourceMessages,
                redactsGroupNames: redactsGroupNames
              )
            }
          }
        }

        if !result.validationWarnings.isEmpty {
          analysisSection("结果校验", symbol: "checkmark.shield") {
            ForEach(result.validationWarnings, id: \.rawValue) { warning in
              Label(warning.workspaceTitle, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
            }
          }
        }

        analysisSection("生成信息", symbol: "info.circle") {
          metadataLine("服务", "\(providerName) · \(result.provenance.model)")
          metadataLine(
            "生成时间",
            result.provenance.generatedAt.formatted(
              .dateTime.year().month().day().hour().minute().second()
            )
          )
          if let usage = result.usage {
            metadataLine("Token", tokenUsage(usage))
          }
        }
      }
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func tokenUsage(_ usage: AIAnalysisUsage) -> String {
    let input = usage.inputTokens.map(String.init) ?? "未知"
    let output = usage.outputTokens.map(String.init) ?? "未知"
    return "输入 \(input) · 输出 \(output)"
  }

  private func metadataLine(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(title)
        .foregroundStyle(.secondary)
        .frame(width: 64, alignment: .leading)
      Text(value)
        .textSelection(.enabled)
      Spacer(minLength: 0)
    }
    .font(.caption)
  }

  private func analysisSection<Content: View>(
    _ title: String,
    symbol: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(title, systemImage: symbol)
        .font(.headline)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct AnalysisCryptoAddressRow: View {
  @EnvironmentObject private var model: AppModel
  let address: AIAnalysisCryptoAddress
  let sourceMessages: [String: MessageEvent]
  let redactsGroupNames: Bool
  let onOpenMeme: (AIAnalysisCryptoAddress) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text(address.address)
          .font(.callout.monospaced())
          .textSelection(.enabled)
          .lineLimit(2)
        Spacer(minLength: 8)
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(address.address, forType: .string)
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("复制地址")
        Button {
          onOpenMeme(address)
        } label: {
          Image(systemName: "chart.line.uptrend.xyaxis")
        }
        .buttonStyle(.borderless)
        .help("查询 Meme 数据")
        Button {
          model.presentManualBuy(for: address)
        } label: {
          Image(systemName: "bolt.horizontal.circle.fill")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(WxFomoTheme.priority)
        .help("打开快速买入；点击立即买入后直接提交")
      }

      FlowLayout(spacing: 10) {
        Label(displayNetworkTitle, systemImage: displayNetworkSymbol)
        if let snapshot = model.caTokenSnapshot(for: address) {
          Label(tokenTitle(snapshot), systemImage: "bitcoinsign.circle.fill")
        }
        Label(address.roleHint.workspaceTitle, systemImage: "tag")
        Label("出现 \(address.occurrenceCount) 次", systemImage: "number")
        Label(
          "上下文：\(address.epistemicStatus.workspaceTitle)",
          systemImage: address.epistemicStatus.workspaceSymbol
        )
        .foregroundStyle(address.epistemicStatus.workspaceColor)
      }
      .font(.caption)

      Text(address.contextSummary)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

      AnalysisSourceLinks(
        sourceIDs: address.sourceMessageIDs,
        sourceMessages: sourceMessages,
        redactsGroupNames: redactsGroupNames
      )
    }
    .padding(.vertical, 3)
  }

  private var displayNetworkTitle: String {
    if let snapshot = model.caTokenSnapshot(for: address) {
      return snapshot.chain.localizedTitle
    }
    return address.network == .solana ? "Solana" : "网络待识别"
  }

  private var displayNetworkSymbol: String {
    address.network == .solana ? "s.circle" : "link.circle"
  }

  private func tokenTitle(_ snapshot: CATokenMarketSnapshot) -> String {
    if !snapshot.symbol.isEmpty, !snapshot.name.isEmpty,
      snapshot.symbol.caseInsensitiveCompare(snapshot.name) != .orderedSame
    {
      return "\(snapshot.symbol) · \(snapshot.name)"
    }
    if !snapshot.symbol.isEmpty { return snapshot.symbol }
    if !snapshot.name.isEmpty { return snapshot.name }
    return "币名待识别"
  }
}

private struct AnalysisFindingRow: View {
  let finding: AIAnalysisFinding
  let sourceMessages: [String: MessageEvent]
  let redactsGroupNames: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        Label(finding.category.workspaceTitle, systemImage: finding.category.workspaceSymbol)
          .font(.caption.weight(.medium))
        Label(
          finding.epistemicStatus.workspaceTitle,
          systemImage: finding.epistemicStatus.workspaceSymbol
        )
        .font(.caption)
        .foregroundStyle(finding.epistemicStatus.workspaceColor)
      }
      Text(finding.text)
        .textSelection(.enabled)
      AnalysisSourceLinks(
        sourceIDs: finding.sourceMessageIDs,
        sourceMessages: sourceMessages,
        redactsGroupNames: redactsGroupNames
      )
    }
    .padding(.vertical, 2)
  }
}

private struct AnalysisSourceLinks: View {
  let sourceIDs: [String]
  let sourceMessages: [String: MessageEvent]
  let redactsGroupNames: Bool
  @State private var visibleCount = 24

  private static let pageSize = 48

  var body: some View {
    if sourceIDs.isEmpty {
      Label("没有可验证来源", systemImage: "link.badge.plus")
        .font(.caption)
        .foregroundStyle(.orange)
    } else {
      VStack(alignment: .leading, spacing: 7) {
        FlowLayout(spacing: 8) {
          ForEach(Array(sourceIDs.prefix(visibleCount).enumerated()), id: \.offset) {
            index, sourceID in
            AnalysisSourceLink(
              sourceID: sourceID,
              ordinal: index + 1,
              event: sourceMessages[sourceID],
              redactsGroupNames: redactsGroupNames
            )
          }
        }

        if sourceIDs.count > visibleCount {
          Button {
            visibleCount = min(visibleCount + Self.pageSize, sourceIDs.count)
          } label: {
            Label(
              "加载更多来源（已显示 \(visibleCount) / \(sourceIDs.count)）",
              systemImage: "plus.circle"
            )
            .font(.caption)
          }
          .buttonStyle(.link)
          .help("按需加载更多来源，避免一次渲染全部引用")
        }
      }
    }
  }
}

private struct AnalysisSourceLink: View {
  let sourceID: String
  let ordinal: Int
  let event: MessageEvent?
  let redactsGroupNames: Bool
  @State private var showsSource = false

  var body: some View {
    Button {
      showsSource = true
    } label: {
      Label(sourceLabel, systemImage: "quote.bubble")
        .font(.caption)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: 220, alignment: .leading)
    }
    .buttonStyle(.link)
    .disabled(event == nil)
    .help(event == nil ? "冻结范围中未找到这条来源消息" : "查看来源消息")
    .popover(isPresented: $showsSource, arrowEdge: .bottom) {
      if let event {
        AnalysisSourcePreview(
          event: event,
          sourceID: sourceID,
          groupName: redactsGroupNames ? "***" : event.group
        )
      }
    }
  }

  private var sourceLabel: String {
    guard let event else { return "来源 \(ordinal)（不可用）" }
    let sender = event.senderDisplayName ?? "发送者未知"
    return "\(ordinal) · \(sender) · \(event.observedAt.formatted(.dateTime.hour().minute()))"
  }
}

private struct AnalysisSourcePreview: View {
  let event: MessageEvent
  let sourceID: String
  let groupName: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(event.senderDisplayName ?? "发送者未知")
          .font(.headline)
        Spacer()
        Text(event.observedAt, format: .dateTime.year().month().day().hour().minute().second())
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Text("\(groupName) · \(event.messageType.workspaceTitle)")
        .font(.caption)
        .foregroundStyle(.secondary)
      Divider()
      ScrollView {
        Text(event.content)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
      Text(sourceID)
        .font(.caption2.monospaced())
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .textSelection(.enabled)
    }
    .padding(16)
    .frame(width: 380, height: 230)
  }
}

struct RulesWorkspaceView: View {
  @EnvironmentObject private var model: AppModel
  @State private var showsEditor = false
  @State private var isInstallingRecommendations = false
  @State private var recommendationStatus: String?
  @State private var currentPage = 1

  var body: some View {
    WorkspacePage(title: "监控规则", subtitle: "确定性筛选、标签与提醒") {
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 2) {
            Text("\(model.messageRules.count) 条规则")
              .font(.caption)
              .foregroundStyle(.secondary)
            if let recommendationStatus {
              Text(recommendationStatus)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
          }
          Spacer()
          Button(action: installRecommendations) {
            if isInstallingRecommendations {
              ProgressView()
                .controlSize(.small)
            } else {
              Label("配置推荐规则", systemImage: "wand.and.stars")
            }
          }
          .disabled(isInstallingRecommendations)
          .help("安装或更新适合加密群信息流的低噪声规则")
          Button {
            showsEditor = true
          } label: {
            Label("新建规则", systemImage: "plus")
          }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        Divider()

        if model.messageRules.isEmpty {
          ContentUnavailableView {
            Label("还没有监控规则", systemImage: "line.3.horizontal.decrease")
          } description: {
            Text("新消息入库后会按优先级执行已启用规则。")
          } actions: {
            Button("新建规则") { showsEditor = true }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(pagedRules, id: \.id) { rule in
                MessageRuleRow(rule: rule)
                  .environmentObject(model)
                Divider()
                  .padding(.leading, 58)
              }
            }
          }
          PaginationBar(totalCount: model.messageRules.count, currentPage: $currentPage)
        }
      }
      .sheet(isPresented: $showsEditor) {
        MessageRuleEditorView()
          .environmentObject(model)
      }
    }
  }

  private var pagedRules: [MessageRule] {
    model.messageRules.pageItems(page: currentPage)
  }

  private func installRecommendations() {
    isInstallingRecommendations = true
    Task {
      let changedCount = await model.installRecommendedMessageRules()
      isInstallingRecommendations = false
      guard let changedCount else {
        recommendationStatus = "配置失败，请查看页面错误"
        return
      }
      recommendationStatus = changedCount == 0
        ? "5 条推荐规则已是最新"
        : "已安装或更新 \(changedCount) 条"
    }
  }
}

struct AutomationsWorkspaceView: View {
  @EnvironmentObject private var model: AppModel
  @State private var editingRule: TradeAutomationRule?
  @State private var showsSettings = false
  @State private var showsNodeBus = false
  @State private var pendingDeleteRule: TradeAutomationRule?
  @State private var tradeRulePage = 1
  @State private var simulationPage = 1
  @State private var tradeIntentPage = 1

  var body: some View {
    WorkspacePage(title: "自动化交易", subtitle: "规则、风控、模拟与自动化意图") {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 18) {
          tradeStatusBand
          simulationSection

          if let error = model.tradeAutomationError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.red)
              .padding(10)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(Color.red.opacity(0.08))
          }

          sectionHeader(
            title: "交易规则",
            subtitle: "信息流达到聚合门槛后，先查询行情和安全数据再生成意图"
          ) {
            Button {
              editingRule = TradeAutomationRule(
                name: "新的 CA 模拟策略",
                allowedChains: [.sol],
                createdAt: Date(),
                updatedAt: Date()
              )
            } label: {
              Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
            .help("新建交易规则")
          }

          if model.tradeAutomationRules.isEmpty {
            ContentUnavailableView(
              "暂无交易规则",
              systemImage: "slider.horizontal.3",
              description: Text("新建规则后，CA 信号会先经过聚合和安全检查。")
            )
            .frame(maxWidth: .infinity, minHeight: 180)
          } else {
            ForEach(pagedTradeRules) { rule in
              tradeRuleRow(rule)
            }
            PaginationBar(
              totalCount: model.tradeAutomationRules.count,
              currentPage: $tradeRulePage,
              showsTopDivider: false
            )
          }

          sectionHeader(
            title: "最近意图",
            subtitle: "模拟、拦截、报价与等待确认均保留原始证据"
          ) {
            Button(action: model.refreshTradeAutomationWorkspace) {
              Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(model.isRefreshingTradeAutomation)
            .help("刷新交易记录")
          }

          if automationTradeIntents.isEmpty {
            Text("等待符合规则的 CA 信号")
              .font(.callout)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, minHeight: 90)
          } else {
            VStack(spacing: 0) {
              ForEach(Array(pagedTradeIntents.enumerated()), id: \.element.id) {
                index, intent in
                tradeIntentRow(intent)
                if index < pagedTradeIntents.count - 1 { Divider() }
              }
            }
            .overlay {
              RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            PaginationBar(
              totalCount: automationTradeIntents.count,
              currentPage: $tradeIntentPage,
              showsTopDivider: false
            )
          }

          nodeBusSection
        }
        .padding(22)
      }
      .onAppear {
        model.refreshAutomationStatus()
        model.refreshTradeAutomationWorkspace()
      }
      .sheet(item: $editingRule) { rule in
        TradeAutomationRuleEditor(rule: rule) { saved in
          try await model.saveTradeAutomationRule(saved)
        }
      }
      .sheet(isPresented: $showsSettings) {
        TradeAutomationSettingsView(configuration: model.tradeAutomationConfiguration) {
          model.updateTradeAutomationConfiguration($0)
        }
      }
      .confirmationDialog(
        "删除这条交易规则？",
        isPresented: Binding(
          get: { pendingDeleteRule != nil },
          set: { if !$0 { pendingDeleteRule = nil } }
        ),
        titleVisibility: .visible
      ) {
        Button("删除", role: .destructive) {
          if let rule = pendingDeleteRule { model.deleteTradeAutomationRule(rule) }
          pendingDeleteRule = nil
        }
        Button("取消", role: .cancel) { pendingDeleteRule = nil }
      }
    }
  }

  private var pagedTradeRules: [TradeAutomationRule] {
    model.tradeAutomationRules.pageItems(page: tradeRulePage)
  }

  private var pagedTradeIntents: [TradeIntent] {
    automationTradeIntents.pageItems(page: tradeIntentPage)
  }

  private var automationTradeIntents: [TradeIntent] {
    model.tradeIntents.filter { $0.ruleID != "manual-buy" && $0.ruleID != "manual-sell" }
  }

  private var tradeStatusBand: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 16) {
        VStack(alignment: .leading, spacing: 5) {
          Label("交易控制", systemImage: "shield.lefthalf.filled")
            .font(.headline)
          Text("信号自动识别、检查并报价；每笔真实交易由买入按钮授权")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Picker(
          "模式",
          selection: Binding(
            get: { model.tradeAutomationConfiguration.mode },
            set: model.setTradeAutomationMode
          )
        ) {
          ForEach(TradeAutomationMode.allCases) { mode in
            Text(mode.localizedTitle).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 300)

        Button(action: model.toggleTradeEmergencyStop) {
          Label(
            model.tradeAutomationConfiguration.emergencyStopped ? "解除急停" : "紧急停止",
            systemImage: model.tradeAutomationConfiguration.emergencyStopped
              ? "lock.open" : "stop.circle.fill"
          )
        }
        .buttonStyle(.borderedProminent)
        .tint(model.tradeAutomationConfiguration.emergencyStopped ? .orange : .red)

        Button { showsSettings = true } label: {
          Image(systemName: "gearshape")
        }
        .buttonStyle(.bordered)
        .help("交易限制与钱包公钥")

        Button(action: model.runTradeAutomationSimulation) {
          Label("试跑规则", systemImage: "play.fill")
        }
        .buttonStyle(.bordered)
        .disabled(model.tradeAutomationRules.isEmpty)
        .help("用本地固定样本检查规则，不会查询 GMGN 或下单")
      }

      Divider()

      HStack(spacing: 28) {
        tradeMetric(
          "GMGN",
          model.gmgnTradeConfigurationState?.localizedTitle ?? "检查中",
          symbol: "bolt.horizontal.circle",
          color: model.gmgnTradeConfigurationState == .ready ? .green : .orange
        )
        tradeMetric(
          "今日意图",
          "\(model.tradeAutomationMetrics.dailyIntentCount) / \(model.tradeAutomationConfiguration.maximumDailyIntents)",
          symbol: "number.circle",
          color: .blue
        )
        tradeMetric(
          "持仓计数",
          "\(model.tradeAutomationMetrics.openPositionCount) / \(model.tradeAutomationConfiguration.maximumOpenPositions)",
          symbol: "briefcase",
          color: .purple
        )
        tradeMetric(
          "连续失败",
          "\(model.tradeAutomationMetrics.consecutiveFailureCount) / \(model.tradeAutomationConfiguration.maximumConsecutiveFailures)",
          symbol: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90",
          color: model.tradeAutomationMetrics.consecutiveFailureCount > 0 ? .orange : .green
        )
        Spacer()
      }
    }
    .padding(.vertical, 2)
  }

  private var simulationSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Label("本地模拟试跑", systemImage: "testtube.2")
          .font(.headline)
        Spacer()
        if let lastRun = model.tradeSimulationLastRunAt {
          Text("最近：\(lastRun.formatted(date: .omitted, time: .shortened))")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      Text("用固定的安全样本走一遍当前规则，只显示会通过还是会拦截，不会写入交易意图、访问钱包或提交订单。")
        .font(.caption)
        .foregroundStyle(.secondary)

      if model.tradeSimulationResults.isEmpty {
        Text("点击右上角“试跑规则”检查已启用规则。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.vertical, 4)
      } else {
        VStack(spacing: 0) {
          ForEach(pagedSimulationResults) { result in
            simulationResultRow(result)
            if result.id != pagedSimulationResults.last?.id { Divider() }
          }
        }
        .padding(.horizontal, 10)
        .overlay {
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        PaginationBar(
          totalCount: model.tradeSimulationResults.count,
          currentPage: $simulationPage,
          showsTopDivider: false
        )
      }
    }
    .padding(14)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }

  private var pagedSimulationResults: [TradeAutomationSimulationResult] {
    model.tradeSimulationResults.pageItems(page: simulationPage)
  }

  private func simulationResultRow(_ result: TradeAutomationSimulationResult) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: result.isEligible ? "checkmark.circle.fill" : "xmark.octagon.fill")
        .foregroundStyle(result.isEligible ? .green : .orange)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 7) {
          Text(result.ruleName)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
          Text(result.isEligible ? "会通过" : "会拦截")
            .font(.caption.weight(.medium))
            .foregroundStyle(result.isEligible ? .green : .orange)
        }
        Text("\(result.chain?.localizedTitle ?? "未配置网络") · 市值 \(formattedUSD(result.sampleMarketCapUSD)) · 流动性 \(formattedUSD(result.sampleLiquidityUSD)) · 估算支出 \(formattedUSD(result.sampleEstimatedSpendUSD))")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .minimumScaleFactor(0.8)
        if !result.isEligible, let reason = result.reasons.first {
          Text(reason)
            .font(.caption2)
            .foregroundStyle(.orange)
            .lineLimit(2)
        } else if !result.protectionOrders.isEmpty {
          Text(protectionSummaryForSimulation(result))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 4)
    }
    .padding(.vertical, 9)
  }

  private func sectionHeader<Actions: View>(
    title: String,
    subtitle: String,
    @ViewBuilder actions: () -> Actions
  ) -> some View {
    HStack(alignment: .center) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.headline)
        Text(subtitle).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      actions()
    }
  }

  private func tradeMetric(
    _ title: String,
    _ value: String,
    symbol: String,
    color: Color
  ) -> some View {
    HStack(spacing: 8) {
      Image(systemName: symbol)
        .foregroundStyle(color)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 1) {
        Text(value).font(.callout.weight(.semibold))
        Text(title).font(.caption2).foregroundStyle(.secondary)
      }
    }
  }

  private func tradeRuleRow(_ rule: TradeAutomationRule) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: rule.isEnabled ? "shield.checkered" : "shield.slash")
        .font(.title3)
        .foregroundStyle(rule.isEnabled ? Color.green : Color.secondary)
        .frame(width: 28, height: 28)

      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 8) {
          Text(rule.name).font(.headline)
          Text(rule.allowedChains.first?.localizedTitle ?? "未配置网络")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          Spacer()
        }
        Text(ruleSummary(rule))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        HStack(spacing: 14) {
          Label("Rug ≤ \(formattedPercent(rule.maximumRugRatio * 100))", systemImage: "checkmark.shield")
          Label("滑点 ≤ \(rule.maximumSlippagePercent)%", systemImage: "arrow.left.arrow.right")
          Label("冷却 \(formattedDuration(rule.tokenCooldownSeconds))", systemImage: "clock")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        if !rule.protectionOrders.isEmpty {
          Label(protectionSummary(rule), systemImage: "shield.lefthalf.filled")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

      Toggle(
        "",
        isOn: Binding(
          get: { rule.isEnabled },
          set: { model.setTradeAutomationRuleEnabled(rule, enabled: $0) }
        )
      )
      .labelsHidden()

      Button { editingRule = rule } label: {
        Image(systemName: "pencil")
      }
      .buttonStyle(.borderless)
      .help("编辑规则")

      Menu {
        Button("复制规则") {
          var copy = rule
          copy.id = UUID().uuidString
          copy.name += " 副本"
          copy.createdAt = Date()
          copy.updatedAt = Date()
          editingRule = copy
        }
        Divider()
        Button("删除规则", role: .destructive) { pendingDeleteRule = rule }
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.borderlessButton)
      .frame(width: 24)
    }
    .padding(14)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    }
  }

  private func tradeIntentRow(_ intent: TradeIntent) -> some View {
    HStack(alignment: .center, spacing: 12) {
      tokenLogo(intent)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Text(intent.tokenSymbol?.isEmpty == false ? intent.tokenSymbol! : "未知代币")
            .font(.callout.weight(.semibold))
          Text(intent.tokenName ?? "")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Text(intent.state.localizedTitle)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(intentStateColor(intent.state))
        }
        Text(shortAddress(intent.tokenAddress))
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      .frame(minWidth: 170, alignment: .leading)

      VStack(alignment: .leading, spacing: 3) {
        Text("\(intent.distinctGroupCount) 群 · \(intent.mentionCount) 次")
          .font(.caption.weight(.medium))
        Text(intent.sourceGroups.map(model.displayGroupName).joined(separator: "、"))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(minWidth: 120, maxWidth: 220, alignment: .leading)

      VStack(alignment: .leading, spacing: 3) {
        Text("市值 \(formattedUSD(intent.marketSnapshot?.marketCapUSD))")
        Text("流动性 \(formattedUSD(intent.marketSnapshot?.liquidityUSD))")
          .foregroundStyle(.secondary)
      }
      .font(.caption)
      .frame(minWidth: 120, alignment: .leading)

      VStack(alignment: .leading, spacing: 3) {
        Text("\(intent.inputAmountNative.formatted(.number.precision(.fractionLength(0...6)))) \(intent.chain.map(GMGNNativeAsset.symbol(for:)) ?? "")")
          .font(.caption.weight(.medium))
        if let reason = intent.rejectionReasons.first ?? intent.failureReason {
          Text(reason).font(.caption2).foregroundStyle(intentStateColor(intent.state)).lineLimit(2)
        } else if let report = intent.executionReport,
          let received = report.outputAmountNative
        {
          Text("成交 \(received) \(intent.tokenSymbol ?? "代币")")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        } else if intent.quote != nil {
          Text("GMGN 报价已保存").font(.caption2).foregroundStyle(.secondary)
        } else {
          Text(intent.createdAt.formatted(date: .omitted, time: .shortened))
            .font(.caption2).foregroundStyle(.secondary)
        }
      }
      .frame(minWidth: 130, maxWidth: 220, alignment: .leading)

      Spacer(minLength: 6)
      Button { model.openTradeIntentSource(intent) } label: {
        Image(systemName: "scope")
      }
      .buttonStyle(.borderless)
      .help("定位原始消息")
      .disabled(intent.sourceEventIDs.isEmpty)
      Button { model.openMemeMode(for: intent) } label: {
        Image(systemName: "chart.xyaxis.line")
      }
      .buttonStyle(.borderless)
      .help("查看代币详情")
      Button { model.presentManualBuy(for: intent) } label: {
        Image(systemName: "bolt.horizontal.circle.fill")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(WxFomoTheme.priority)
      .help("打开快速买入；点击立即买入后直接提交")
      .disabled(intent.state == .submitting || intent.state == .pending)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .contentShape(Rectangle())
    .contextMenu {
      Button("定位原始消息") { model.openTradeIntentSource(intent) }
      Button("查看代币详情") { model.openMemeMode(for: intent) }
      Button("快速买入") { model.presentManualBuy(for: intent) }
      Button("复制 CA") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(intent.tokenAddress, forType: .string)
      }
    }
  }

  @ViewBuilder
  private func tokenLogo(_ intent: TradeIntent) -> some View {
    if let value = intent.tokenLogoURL, let url = URL(string: value), url.scheme == "https" {
      AsyncImage(url: url) { phase in
        if let image = phase.image {
          image.resizable().scaledToFill()
        } else {
          Image(systemName: "bitcoinsign.circle.fill")
            .resizable().scaledToFit().foregroundStyle(.secondary)
        }
      }
      .frame(width: 34, height: 34)
      .clipShape(RoundedRectangle(cornerRadius: 6))
    } else {
      Image(systemName: "bitcoinsign.circle.fill")
        .resizable().scaledToFit()
        .foregroundStyle(.orange)
        .frame(width: 34, height: 34)
    }
  }

  private var nodeBusSection: some View {
    DisclosureGroup(isExpanded: $showsNodeBus) {
      VStack(spacing: 0) {
        HStack {
          Text("只读消息事件")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Toggle(
            "",
            isOn: Binding(
              get: { model.automationEnabled },
              set: model.setAutomationEnabled
            )
          )
          .labelsHidden()
        }
        .padding(.vertical, 10)
        Divider()
        automationRow("状态", value: automationState, symbol: "circle.dotted")
        Divider()
        automationRow("连接 Worker", value: "\(model.automationStatus?.connectedClients ?? 0)", symbol: "point.3.connected.trianglepath.dotted")
        Divider()
        automationRow("已发布事件", value: "\(model.automationStatus?.publishedEvents ?? 0)", symbol: "arrow.up.forward")
        Divider()
        automationRow("Socket", value: "~/Library/Application Support/wxFomo/automation/events.sock", symbol: "cable.connector")
        if let error = model.automationError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.red).padding(.top, 10)
        }
      }
      .padding(.leading, 6)
    } label: {
      Label("Node.js 本机事件总线", systemImage: "terminal")
        .font(.headline)
    }
    .padding(.top, 4)
  }

  private var automationState: String {
    guard model.automationEnabled else { return "已关闭" }
    switch model.automationStatus?.state {
    case .listening: return "监听中"
    case .failed: return "启动失败"
    case .stopped: return "已停止"
    case .disabled: return "已禁用"
    case nil: return "正在启动"
    }
  }

  private func automationRow(_ title: String, value: String, symbol: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .foregroundStyle(.secondary)
        .frame(width: 20)
      Text(title)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
    .padding(.vertical, 12)
  }

  private func ruleSummary(_ rule: TradeAutomationRule) -> String {
    let minutes = Int(rule.aggregationWindowSeconds / 60)
    return "\(minutes) 分钟 · 至少 \(rule.minimumDistinctGroups) 群 / \(rule.minimumMentions) 次 · 市值 \(formattedUSD(rule.minimumMarketCapUSD))–\(formattedUSD(rule.maximumMarketCapUSD)) · 流动性 ≥ \(formattedUSD(rule.minimumLiquidityUSD)) · 买入 \(rule.inputAmountNative.formatted(.number.precision(.fractionLength(0...6)))) \(rule.allowedChains.first.map(GMGNNativeAsset.symbol(for:)) ?? "")"
  }

  private func protectionSummary(_ rule: TradeAutomationRule) -> String {
    rule.protectionOrders.map { order in
      "\(order.triggerDescription) 卖 \(formattedPercent(order.sellPercent))"
    }.joined(separator: "；")
  }

  private func protectionSummaryForSimulation(_ result: TradeAutomationSimulationResult) -> String {
    result.protectionOrders.map { order in
      "\(order.triggerDescription) 卖 \(formattedPercent(order.sellPercent))"
    }.joined(separator: "；")
  }

  private func formattedUSD(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "未知" }
    if abs(value) >= 1_000_000_000 { return "$" + (value / 1_000_000_000).formatted(.number.precision(.fractionLength(1...2))) + "B" }
    if abs(value) >= 1_000_000 { return "$" + (value / 1_000_000).formatted(.number.precision(.fractionLength(1...2))) + "M" }
    if abs(value) >= 1_000 { return "$" + (value / 1_000).formatted(.number.precision(.fractionLength(1...2))) + "K" }
    return value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
  }

  private func formattedPercent(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...2))) + "%"
  }

  private func formattedDuration(_ value: TimeInterval) -> String {
    if value >= 24 * 60 * 60 { return "\(Int(value / (24 * 60 * 60))) 天" }
    if value >= 60 * 60 { return "\(Int(value / (60 * 60))) 小时" }
    return "\(Int(value / 60)) 分钟"
  }

  private func shortAddress(_ value: String) -> String {
    guard value.count > 16 else { return value }
    return "\(value.prefix(8))…\(value.suffix(6))"
  }

  private func intentStateColor(_ state: TradeIntentState) -> Color {
    switch state {
    case .simulated, .confirmed: return .green
    case .awaitingConfirmation, .quoted, .eligible: return .blue
    case .detected, .pending, .submitting: return .orange
    case .rejected: return .secondary
    case .failed, .unprotectedPosition: return .red
    }
  }
}

struct TradeAutomationSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var draft: TradeAutomationConfiguration
  @State private var wallet: String
  let onSave: (TradeAutomationConfiguration) -> Void

  init(
    configuration: TradeAutomationConfiguration,
    onSave: @escaping (TradeAutomationConfiguration) -> Void
  ) {
    _draft = State(initialValue: configuration)
    _wallet = State(initialValue: configuration.walletAddress ?? "")
    self.onSave = onSave
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("交易限制").font(.title3.weight(.semibold))
          Text("交易优先使用当前 API Key 返回的按链钱包；请求签名密钥由 gmgn-cli 管理")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button { dismiss() } label: { Image(systemName: "xmark") }
          .buttonStyle(.borderless)
      }
      .padding(18)
      Divider()
      Form {
        Section("兼容回退钱包（可选）") {
          TextField("Solana 或 0x 钱包公钥", text: $wallet)
            .textFieldStyle(.roundedBorder)
          Text("只有 API Key 未返回当前网络钱包时才使用；一个地址不能同时替代 Solana 与 EVM 钱包。此处只填公钥，不填私钥。")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("全局硬限制") {
          LabeledContent("每日意图上限") {
            Stepper("\(draft.maximumDailyIntents)", value: $draft.maximumDailyIntents, in: 1...100)
          }
          LabeledContent("最大持仓计数") {
            Stepper("\(draft.maximumOpenPositions)", value: $draft.maximumOpenPositions, in: 1...100)
          }
          LabeledContent("连续失败熔断") {
            Stepper("\(draft.maximumConsecutiveFailures)", value: $draft.maximumConsecutiveFailures, in: 1...20)
          }
          LabeledContent("每日美元上限") {
            TextField("", value: $draft.maximumDailySpendUSD, format: .number)
              .labelsHidden()
              .multilineTextAlignment(.trailing)
              .frame(width: 170)
          }
          Text("美元上限开启后，无法可靠估算成本的信号会被拦截。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      Divider()
      HStack {
        Spacer()
        Button("取消") { dismiss() }
        Button("保存") {
          draft.walletAddress = wallet
          onSave(draft.normalized)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
      }
      .padding(14)
    }
    .frame(width: 560, height: 510)
  }
}

private struct TradeAutomationRuleEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State private var draft: TradeAutomationRule
  @State private var selectedChain: GMGNChain
  @State private var groupsText: String
  @State private var sendersText: String
  @State private var windowMinutes: Double
  @State private var cooldownHours: Double
  @State private var isSaving = false
  @State private var errorText: String?
  let onSave: (TradeAutomationRule) async throws -> Void

  init(
    rule: TradeAutomationRule,
    onSave: @escaping (TradeAutomationRule) async throws -> Void
  ) {
    _draft = State(initialValue: rule)
    _selectedChain = State(initialValue: rule.allowedChains.first ?? .sol)
    _groupsText = State(initialValue: rule.groups.joined(separator: "，"))
    _sendersText = State(initialValue: rule.senders.joined(separator: "，"))
    _windowMinutes = State(initialValue: rule.aggregationWindowSeconds / 60)
    _cooldownHours = State(initialValue: rule.tokenCooldownSeconds / 3600)
    self.onSave = onSave
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("CA 交易规则").font(.title3.weight(.semibold))
          Text("先聚合，再查行情和安全数据；AI 不作为唯一触发条件")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button { dismiss() } label: { Image(systemName: "xmark") }
          .buttonStyle(.borderless)
      }
      .padding(18)
      Divider()
      Form {
        Section("基本") {
          TextField("规则名称", text: $draft.name)
          Toggle("启用规则", isOn: $draft.isEnabled)
          Picker("网络", selection: $selectedChain) {
            ForEach([GMGNChain.sol, .eth, .base, .bsc]) { chain in
              Text(chain.localizedTitle).tag(chain)
            }
          }
          Text("每条规则只使用一种原生资产；多网络请复制并分别配置。")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("信号聚合") {
          LabeledContent("统计窗口（分钟）") {
            TextField("", value: $windowMinutes, format: .number)
              .labelsHidden()
              .multilineTextAlignment(.trailing)
              .frame(width: 150)
          }
          Stepper("至少 \(draft.minimumDistinctGroups) 个独立群", value: $draft.minimumDistinctGroups, in: 1...20)
          Stepper("至少 \(draft.minimumMentions) 次提及", value: $draft.minimumMentions, in: 1...100)
          TextField("限定群名，用逗号分隔；留空表示全部", text: $groupsText)
          TextField("限定发送者，用逗号分隔；留空表示全部", text: $sendersText)
        }
        Section("行情与安全") {
          LabeledContent("最低市值 USD") {
            TextField("", value: $draft.minimumMarketCapUSD, format: .number)
              .labelsHidden().multilineTextAlignment(.trailing).frame(width: 180)
          }
          LabeledContent("最高市值 USD") {
            TextField("", value: $draft.maximumMarketCapUSD, format: .number)
              .labelsHidden().multilineTextAlignment(.trailing).frame(width: 180)
          }
          LabeledContent("最低流动性 USD") {
            TextField("", value: $draft.minimumLiquidityUSD, format: .number)
              .labelsHidden().multilineTextAlignment(.trailing).frame(width: 180)
          }
          LabeledContent("最高 Rug 比例") {
            TextField("", value: $draft.maximumRugRatio, format: .number)
              .labelsHidden().multilineTextAlignment(.trailing).frame(width: 180)
          }
          Toggle("安全数据缺失时拦截", isOn: $draft.requireSecurityData)
        }
        Section("执行限制") {
          LabeledContent("买入原生资产数量") {
            TextField("", value: $draft.inputAmountNative, format: .number)
              .labelsHidden().multilineTextAlignment(.trailing).frame(width: 160)
          }
          Stepper("最大滑点 \(draft.maximumSlippagePercent)%", value: $draft.maximumSlippagePercent, in: 1...100)
          Toggle("Anti-MEV（Base 会自动忽略）", isOn: $draft.antiMEV)
          Stepper("每日最多 \(draft.maximumTradesPerDay) 次", value: $draft.maximumTradesPerDay, in: 1...100)
          LabeledContent("同币冷却（小时）") {
            TextField("", value: $cooldownHours, format: .number)
              .labelsHidden().multilineTextAlignment(.trailing).frame(width: 160)
          }
        }
        Section("成交后保护") {
          ForEach(draft.protectionOrders.indices, id: \.self) { index in
            HStack {
              Picker("", selection: $draft.protectionOrders[index].kind) {
                ForEach(TradeProtectionOrder.Kind.allCases, id: \.rawValue) { kind in
                  Text(kind.localizedTitle).tag(kind)
                }
              }
              .labelsHidden().frame(width: 90)
              Text(draft.protectionOrders[index].kind == .takeProfit ? "上涨" : "下跌")
              TextField("", value: $draft.protectionOrders[index].triggerPercent, format: .number)
                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 70)
              Text("% · 卖出")
              TextField("", value: $draft.protectionOrders[index].sellPercent, format: .number)
                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 70)
              Text("%")
              Spacer()
              Button {
                draft.protectionOrders.remove(at: index)
              } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).foregroundStyle(.red)
            }
          }
          let takeProfitSellTotal = draft.protectionOrders
            .filter { $0.kind == .takeProfit }
            .reduce(0) { $0 + $1.sellPercent }
          Text("示例：上涨 100% 卖出 50%，上涨 200% 再卖出 50%，下跌 50% 清仓。止盈卖出比例合计：\(takeProfitSellTotal.formatted(.number.precision(.fractionLength(0...2))))%")
            .font(.caption)
            .foregroundStyle(takeProfitSellTotal > 100 ? .red : .secondary)
          Menu {
            Button("使用推荐方案") {
              draft.protectionOrders = [
                TradeProtectionOrder(kind: .takeProfit, triggerPercent: 100, sellPercent: 50),
                TradeProtectionOrder(kind: .takeProfit, triggerPercent: 200, sellPercent: 50),
                TradeProtectionOrder(kind: .stopLoss, triggerPercent: 50, sellPercent: 100),
              ]
            }
            Divider()
            Button("添加止盈") {
              draft.protectionOrders.append(
                TradeProtectionOrder(kind: .takeProfit, triggerPercent: 100, sellPercent: 50)
              )
            }
            Button("添加止损") {
              draft.protectionOrders.append(
                TradeProtectionOrder(kind: .stopLoss, triggerPercent: 50, sellPercent: 100)
              )
            }
          } label: {
            Label("添加保护", systemImage: "plus")
          }
          .disabled(draft.protectionOrders.count >= 10)
          Text("保护单只作为交易计划保存；真实成交后必须验证 GMGN 是否成功创建策略单。")
            .font(.caption).foregroundStyle(.secondary)
        }
        if let errorText {
          Section { Label(errorText, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
        }
      }
      .formStyle(.grouped)
      Divider()
      HStack {
        Spacer()
        Button("取消") { dismiss() }
        Button("保存") { save() }
          .buttonStyle(.borderedProminent)
          .disabled(isSaving)
      }
      .padding(14)
    }
    .frame(width: 680, height: 760)
  }

  private func save() {
    var saved = draft
    saved.allowedChains = [selectedChain]
    saved.groups = splitValues(groupsText)
    saved.senders = splitValues(sendersText)
    saved.aggregationWindowSeconds = windowMinutes * 60
    saved.tokenCooldownSeconds = cooldownHours * 3600
    saved.updatedAt = Date()
    guard saved.validationIssues.isEmpty else {
      errorText = saved.validationIssues.joined(separator: "；")
      return
    }
    let normalized = saved.normalized
    isSaving = true
    Task {
      do {
        try await onSave(normalized)
        dismiss()
      } catch {
        errorText = error.localizedDescription
        isSaving = false
      }
    }
  }

  private func splitValues(_ value: String) -> [String] {
    value.split(whereSeparator: { ",，\n".contains($0) })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}

struct ProviderWorkspaceView: View {
  @EnvironmentObject private var model: AppModel
  @State private var showsEditor = false
  @State private var editingConfiguration: AIProviderConfiguration?
  @State private var speechDraft = NotificationSpeechConfiguration()
  @State private var speechAPIKeyDraft = ""
  @State private var showsSpeechAdvancedSettings = false
  @State private var providerPage = 1

  var body: some View {
    WorkspacePage(title: "配置中心", subtitle: "模型、语音、端点与本地凭据") {
      VStack(spacing: 0) {
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Label("统一本地配置", systemImage: "externaldrive.fill")
            Text("不读取钥匙串或环境变量。API Key 保存在权限为 0600 的本地配置文件中。")
            Text(model.configurationCenterPath)
              .font(.caption.monospaced())
              .textSelection(.enabled)
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        Divider()

        ScrollView {
          VStack(spacing: 0) {
            setupChecklistSection
            Divider()
              .padding(.horizontal, 22)
            speechConfigurationSection
            Divider()
              .padding(.horizontal, 22)
            aiProviderSection
          }
        }

        if let error = model.workspaceStoreError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
        }
      }
      .sheet(isPresented: $showsEditor) {
        ProviderEditorView(configuration: editingConfiguration)
          .environmentObject(model)
      }
      .onAppear {
        speechDraft = model.soundConfiguration.speech
        model.refreshStatus()
      }
    }
  }

  private var setupChecklistSection: some View {
    SetupChecklistView(
      onConfigureAI: {
        editingConfiguration = model.providerConfigurations.first { configuration in
          if let defaultProviderID = model.defaultProviderID {
            return configuration.configurationID == defaultProviderID
          }
          return true
        }
        showsEditor = true
      },
      onConfigureSpeech: {
        speechDraft.provider = .volcengineSeed
      }
    )
    .environmentObject(model)
  }

  private var speechConfigurationSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Label("真人语音 / TTS", systemImage: "waveform")
            .font(.headline)
          Text("通知规则只引用这里选定的语音服务和音色。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let status = model.soundStatusText {
          Text(status)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        Button {
          model.previewConfiguredSpeech()
        } label: {
          Label("试听", systemImage: "play.fill")
        }
      }

      Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
        speechRow("语音来源") {
          Picker("", selection: $speechDraft.provider) {
            ForEach(NotificationSpeechProvider.allCases) { provider in
              Text(provider.localizedTitle).tag(provider)
            }
          }
          .labelsHidden()
          .frame(maxWidth: 360)
        }

        if speechDraft.provider == .volcengineSeed {
          speechRow("火山音色") {
            Picker("", selection: $speechDraft.voiceID) {
              ForEach(NotificationSpeechVoiceChoice.allCases) { voice in
                Text(voice.localizedTitle).tag(voice.rawValue)
              }
            }
            .labelsHidden()
            .frame(maxWidth: 360)
          }

          speechRow("火山 API Key") {
            HStack(spacing: 8) {
              SecureField(
                model.isSpeechAPIKeyConfigured ? "已配置，留空保持现有值" : "输入 UUID X-Api-Key",
                text: $speechAPIKeyDraft
              )
              .textFieldStyle(.roundedBorder)
              .frame(maxWidth: 360)
              if model.isSpeechAPIKeyConfigured {
                Label("已配置", systemImage: "checkmark.circle.fill")
                  .font(.caption)
                  .foregroundStyle(.green)
                Button(role: .destructive) {
                  model.deleteSpeechAPIKey()
                } label: {
                  Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除火山语音 API Key")
              }
            }
          }

          speechRow("失败回退") {
            Toggle(
              "火山语音不可用时使用系统中文语音",
              isOn: $speechDraft.fallbackToSystemVoice
            )
          }

          speechRow("兼容回退") {
            Toggle(
              "流式接口失败时尝试创建接口",
              isOn: $speechDraft.fallbackToCreateEndpoint
            )
          }
        }
      }

      if speechDraft.provider == .volcengineSeed {
        DisclosureGroup("高级参数", isExpanded: $showsSpeechAdvancedSettings) {
          Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
            speechRow("创建 Endpoint") {
              TextField("Endpoint", text: $speechDraft.seedEndpoint)
                .textFieldStyle(.roundedBorder)
            }
            speechRow("流式 Endpoint") {
              TextField("Stream Endpoint", text: $speechDraft.seedStreamEndpoint)
                .textFieldStyle(.roundedBorder)
            }
            speechRow("流式模型") {
              TextField("Stream Model", text: $speechDraft.seedStreamModel)
                .textFieldStyle(.roundedBorder)
            }
            speechRow("创建模型") {
              TextField("Model", text: $speechDraft.seedModel)
                .textFieldStyle(.roundedBorder)
            }
            speechRow("Resource ID") {
              TextField("Resource ID", text: $speechDraft.seedResourceID)
                .textFieldStyle(.roundedBorder)
            }
            speechRow("音频格式") {
              Picker("", selection: $speechDraft.audioFormat) {
                Text("MP3").tag("mp3")
                Text("WAV").tag("wav")
              }
              .labelsHidden()
              .frame(width: 140)
            }
            speechRow("采样率") {
              TextField("采样率", value: $speechDraft.sampleRate, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
            }
            speechRow("单次字数上限") {
              TextField("字数", value: $speechDraft.maximumCharacters, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
            }
            speechRow("缓存秒数") {
              TextField("秒", value: $speechDraft.cacheTTLSeconds, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
            }
            speechRow("请求超时") {
              TextField(
                "秒",
                value: $speechDraft.requestTimeoutSeconds,
                format: .number.precision(.fractionLength(0...1))
              )
              .textFieldStyle(.roundedBorder)
              .frame(width: 140)
            }
          }
          .padding(.top, 10)
        }
      }

      HStack {
        Spacer()
        Button {
          speechDraft = NotificationSpeechConfiguration()
        } label: {
          Label("恢复默认参数", systemImage: "arrow.counterclockwise")
        }
        Button {
          if model.saveSpeechServiceConfiguration(
            speechDraft,
            apiKey: speechAPIKeyDraft
          ) {
            speechDraft = model.soundConfiguration.speech
            speechAPIKeyDraft = ""
          }
        } label: {
          Label("保存语音配置", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(22)
  }

  private var aiProviderSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Label("AI 模型服务", systemImage: "network")
            .font(.headline)
          Text("配置摘要、分析和自动化所使用的模型协议与凭据。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          editingConfiguration = nil
          showsEditor = true
        } label: {
          Label("添加服务", systemImage: "plus")
        }
      }
      .padding(22)

      if model.providerConfigurations.isEmpty {
        HStack(spacing: 12) {
          Image(systemName: "network.slash")
            .font(.title2)
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 3) {
            Text("还没有 AI 模型服务")
              .font(.callout.weight(.semibold))
            Text("添加服务后即可分析冻结的消息范围。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
      } else {
        LazyVStack(spacing: 0) {
          ForEach(pagedProviderConfigurations) { configuration in
            ProviderConfigurationRow(
              configuration: configuration,
              onEdit: { configuration in
                editingConfiguration = configuration
                showsEditor = true
              }
            )
            .environmentObject(model)
            Divider()
              .padding(.leading, 58)
          }
        }
        PaginationBar(
          totalCount: model.providerConfigurations.count,
          currentPage: $providerPage
        )
      }
    }
  }

  private var pagedProviderConfigurations: [AIProviderConfiguration] {
    model.providerConfigurations.pageItems(page: providerPage)
  }

  private func speechRow<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    GridRow {
      Text(title)
        .foregroundStyle(.secondary)
        .frame(width: 132, alignment: .trailing)
      content()
        .frame(maxWidth: 620, alignment: .leading)
    }
  }
}

private enum SetupCheckState: Equatable {
  case ready
  case required
  case optional
  case checking

  var symbol: String {
    switch self {
    case .ready: return "checkmark.circle.fill"
    case .required: return "exclamationmark.circle.fill"
    case .optional: return "minus.circle"
    case .checking: return "ellipsis.circle"
    }
  }

  var color: Color {
    switch self {
    case .ready: return .green
    case .required: return .orange
    case .optional: return .secondary
    case .checking: return .secondary
    }
  }

  var title: String {
    switch self {
    case .ready: return "已完成"
    case .required: return "需要配置"
    case .optional: return "可选"
    case .checking: return "检查中"
    }
  }
}

private struct SetupChecklistView: View {
  @EnvironmentObject private var model: AppModel
  let onConfigureAI: () -> Void
  let onConfigureSpeech: () -> Void

  private enum SetupAction {
    case openSettings
    case addGroup
    case configureAI
    case configureSpeech

    var title: String {
      switch self {
      case .openSettings: return "打开设置"
      case .addGroup: return "去添加群聊"
      case .configureAI: return "配置服务"
      case .configureSpeech: return "填写 Key"
      }
    }
  }

  private var listenerStates: [SetupCheckState] {
    [notificationState, groupsState]
  }

  private var listenerReadyCount: Int {
    listenerStates.filter { $0 == .ready }.count
  }

  private var listenerIsReady: Bool {
    listenerReadyCount == 2
  }

  private var aiIsReady: Bool {
    aiState == .ready
  }

  private var notificationState: SetupCheckState {
    guard let report = model.doctorReport else { return .checking }
    return report.notificationDatabaseReadable ? .ready : .required
  }

  private var notificationDetail: String {
    guard let report = model.doctorReport else { return "正在检查通知数据库" }
    guard report.notificationDatabaseReadable else {
      return "需要给 wxFomo 开启“完全磁盘访问”"
    }
    if let rowID = model.notificationLatestRowID, rowID > 0 {
      return "通知数据库可读取，已发现系统通知记录"
    }
    return "通知数据库可读取，等待企业微信通知"
  }

  private var groupsState: SetupCheckState {
    model.groups.isEmpty ? .required : .ready
  }

  private var groupsDetail: String {
    model.groups.isEmpty ? "至少添加一个需要监听的企业微信群名" : "已配置 \(model.groups.count) 个监听群"
  }

  private var selectedAIProvider: AIProviderConfiguration? {
    if let defaultProviderID = model.defaultProviderID,
      let defaultProvider = model.providerConfigurations.first(where: {
        $0.configurationID == defaultProviderID
      })
    {
      return defaultProvider
    }
    return model.providerConfigurations.first
  }

  private var aiState: SetupCheckState {
    guard let provider = selectedAIProvider else { return .required }
    return model.isProviderAPIKeyConfigured(provider) ? .ready : .required
  }

  private var aiDetail: String {
    guard let provider = selectedAIProvider else {
      return "添加一个 AI 服务，并填写对应 API Key；未配置不影响消息监听"
    }
    if model.isProviderAPIKeyConfigured(provider) {
      return "\(provider.displayName) · API Key 已配置"
    }
    return "\(provider.displayName) · API Key 待配置；未配置不影响消息监听"
  }

  private var speechState: SetupCheckState {
    if model.soundConfiguration.speech.provider == .system {
      return .optional
    }
    return model.isSpeechAPIKeyConfigured ? .ready : .optional
  }

  private var speechDetail: String {
    if model.soundConfiguration.speech.provider == .system {
      return "当前使用 macOS 系统语音，不需要 API Key"
    }
    if model.isSpeechAPIKeyConfigured {
      return "火山语音 API Key 已配置"
    }
    return "未配置不会影响消息监听，可继续使用系统语音回退"
  }

  private var checklistBackground: Color {
    Color(nsColor: .controlBackgroundColor).opacity(0.34)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Label("首次使用检查", systemImage: "checklist")
            .font(.headline)
          Text(
            listenerIsReady
              ? (aiIsReady ? "监听与 AI 摘要已就绪" : "可以开始监听；配置 AI 服务后可生成摘要")
              : "先完成通知读取和监听群，再开始监听"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Spacer(minLength: 12)
        Text("监听基础 \(listenerReadyCount)/2")
          .font(.caption.weight(.semibold).monospacedDigit())
          .foregroundStyle(listenerIsReady ? .green : .orange)
        Button {
          model.refreshStatus()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("重新检查通知读取权限")
      }

      VStack(spacing: 0) {
        setupCheckRow(
          title: "通知读取权限",
          detail: notificationDetail,
          state: notificationState,
          action: notificationState == .required ? .openSettings : nil
        )
        Divider()
        setupCheckRow(
          title: "监听群",
          detail: groupsDetail,
          state: groupsState,
          action: groupsState == .required ? .addGroup : nil
        )
        Divider()
        setupCheckRow(
          title: "AI 摘要服务",
          detail: aiDetail,
          state: aiState,
          action: aiState == .required ? .configureAI : nil
        )
        Divider()
        setupCheckRow(
          title: "语音播报",
          detail: speechDetail,
          state: speechState,
          action: speechNeedsKey ? .configureSpeech : nil
        )
        Divider()
        setupCheckRow(
          title: "DexScreener 行情",
          detail: "查询地址时按需访问，不需要额外 API Key",
          state: .optional
        )
        Divider()
        setupCheckRow(
          title: "GMGN 高级能力",
          detail: "安全数据、跟单与高级行情属于可选功能，需要单独配置 GMGN CLI",
          state: .optional
        )
      }

      Text("开始监听前还需要企业微信已运行，并在企业微信和 macOS 通知设置中允许通知。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(22)
    .background(checklistBackground)
  }

  private func setupCheckRow(
    title: String,
    detail: String,
    state: SetupCheckState,
    action: SetupAction? = nil
  ) -> some View {
    HStack(alignment: .top, spacing: 11) {
      Image(systemName: state.symbol)
        .foregroundStyle(state.color)
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 7) {
          Text(title)
            .font(.callout.weight(.semibold))
          Text(state.title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(state.color)
        }
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      if let action {
        Button(action.title) {
          perform(action)
        }
          .buttonStyle(.borderless)
          .foregroundStyle(WxFomoTheme.signal)
          .fixedSize()
      }
    }
    .padding(.vertical, 8)
  }

  private var speechNeedsKey: Bool {
    model.soundConfiguration.speech.provider != .system
      && !model.isSpeechAPIKeyConfigured
  }

  private func perform(_ action: SetupAction) {
    switch action {
    case .openSettings:
      model.openFullDiskAccessSettings()
    case .addGroup:
      model.workspaceSelection = .inbox
    case .configureAI:
      onConfigureAI()
    case .configureSpeech:
      onConfigureSpeech()
    }
  }
}

private struct ProviderConfigurationRow: View {
  @EnvironmentObject private var model: AppModel
  let configuration: AIProviderConfiguration
  let onEdit: (AIProviderConfiguration) -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "network")
        .font(.system(size: 18))
        .foregroundStyle(.secondary)
        .frame(width: 36, height: 36)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 7) {
          Text(configuration.displayName)
            .font(.callout.weight(.semibold))
          if model.defaultProviderID == configuration.configurationID {
            Text("默认")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Text("\(configuration.kind.localizedTitle) · \(configuration.model)")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(configuration.baseURL.absoluteString)
          .font(.caption.monospaced())
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .textSelection(.enabled)
        Label(
          model.isProviderAPIKeyConfigured(configuration) ? "API Key 已配置" : "API Key 待配置",
          systemImage: model.isProviderAPIKeyConfigured(configuration)
            ? "checkmark.circle.fill"
            : "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(
          model.isProviderAPIKeyConfigured(configuration) ? Color.green : Color.orange
        )
        providerConnectionStatus
      }
      Spacer()
      Menu {
        Button {
          onEdit(configuration)
        } label: {
          Label("编辑服务", systemImage: "pencil")
        }
        Button {
          model.testProviderConnection(configuration)
        } label: {
          Label("测试连接", systemImage: "bolt.horizontal.circle")
        }
        .disabled(model.testingProviderIDs.contains(configuration.configurationID))
        if model.defaultProviderID != configuration.configurationID {
          Button("设为默认") { model.setDefaultProvider(configuration) }
        }
        Divider()
        Button("删除", role: .destructive) { model.deleteProvider(configuration) }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .help("服务操作")
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 12)
  }

  @ViewBuilder
  private var providerConnectionStatus: some View {
    if model.testingProviderIDs.contains(configuration.configurationID) {
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.mini)
        Text("正在读取模型目录")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    } else if let result = model.providerConnectionTests[configuration.configurationID] {
      Label(
        result.workspaceMessage(model: configuration.model),
        systemImage: result.status.workspaceSymbol
      )
      .font(.caption)
      .foregroundStyle(result.status.workspaceColor)
      .lineLimit(2)
      .help(result.testedAt.formatted(.dateTime.year().month().day().hour().minute().second()))
    }
  }
}

private struct ProviderEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var model: AppModel
  private let existingConfiguration: AIProviderConfiguration?
  @State private var preset: ProviderPreset
  @State private var draft: ProviderDraft
  @State private var isSaving = false

  init(configuration: AIProviderConfiguration? = nil) {
    existingConfiguration = configuration
    _preset = State(initialValue: configuration == nil ? .supertokenGPT56 : .manual)
    var initialDraft = ProviderDraft(configuration: configuration)
    if configuration == nil {
      initialDraft.apply(.supertokenGPT56)
    }
    _draft = State(initialValue: initialDraft)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(existingConfiguration == nil ? "添加 AI 模型服务" : "编辑 AI 模型服务")
          .font(.title2.weight(.semibold))
        Spacer()
        Button("取消") { dismiss() }
      }
      .padding(22)
      Divider()

      Form {
        Picker("快速预设", selection: $preset) {
          ForEach(ProviderPreset.allCases) { preset in
            Text(preset.title).tag(preset)
          }
        }
        .onChange(of: preset) { _, newPreset in draft.apply(newPreset) }

        if preset == .supertokenGPT56 {
          Label(
            "第三方 OpenAI 兼容网关，不是 OpenAI 官方直连；请填写你自己的 API Key。",
            systemImage: "exclamationmark.shield"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        Label(
          "API Key 只写入配置中心文件，不读取钥匙串、环境变量或其它配置文件。",
          systemImage: "checkmark.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Picker("协议", selection: $draft.kind) {
          ForEach(AIProviderKind.allCases, id: \.self) { kind in
            Text(kind.localizedTitle).tag(kind)
          }
        }
        .onChange(of: draft.kind) { draft.applyKindDefaults() }

        TextField("显示名称", text: $draft.displayName)
        TextField("模型", text: $draft.model)
        TextField("Base URL", text: $draft.baseURL)
          .disabled(draft.kind != .openAICompatibleChatCompletions)
        SecureField(
          existingConfiguration == nil ? "API Key（必填）" : "API Key（留空保持现有）",
          text: $draft.apiKey
        )
        .help("只使用你在配置中心输入的 API Key")
        Toggle("设为默认服务", isOn: $draft.makeDefault)
      }
      .formStyle(.grouped)

      Divider()
      HStack {
        if isSaving {
          ProgressView()
            .controlSize(.small)
        }
        Spacer()
        Button("保存") {
          isSaving = true
          Task {
            let saved = await model.saveProvider(draft)
            isSaving = false
            if saved { dismiss() }
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          isSaving
            || draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (existingConfiguration == nil
              && draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        )
      }
      .padding(16)
    }
    .frame(width: 520, height: 520)
  }
}

private struct MessageRuleRow: View {
  @EnvironmentObject private var model: AppModel
  let rule: MessageRule

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "line.3.horizontal.decrease")
        .font(.system(size: 18))
        .foregroundStyle(.secondary)
        .frame(width: 36, height: 36)
      VStack(alignment: .leading, spacing: 3) {
        Text(rule.name)
          .font(.callout.weight(.semibold))
        Text("优先级 \(rule.priority) · \(conditionSummary)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(actionSummary)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
      Spacer()
      Toggle(
        "",
        isOn: Binding(
          get: { rule.isEnabled },
          set: { model.setMessageRuleEnabled(rule, isEnabled: $0) }
        )
      )
      .labelsHidden()
      Menu {
        Button(rule.isEnabled ? "停用" : "启用") {
          model.setMessageRuleEnabled(rule, isEnabled: !rule.isEnabled)
        }
        Button("复制规则概要") { copyRuleSummary() }
        Divider()
        Button("删除", role: .destructive) { model.deleteMessageRule(rule) }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .help("规则操作")
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 12)
    .contentShape(Rectangle())
    .contextMenu {
      Button(rule.isEnabled ? "停用规则" : "启用规则") {
        model.setMessageRuleEnabled(rule, isEnabled: !rule.isEnabled)
      }
      Button("复制规则概要") { copyRuleSummary() }
    }
  }

  private var conditionSummary: String {
    var parts: [String] = []
    if !rule.condition.groups.isEmpty { parts.append("\(rule.condition.groups.count) 个群") }
    if !rule.condition.senders.isEmpty { parts.append("\(rule.condition.senders.count) 位发送者") }
    if !rule.condition.includeKeywords.isEmpty {
      parts.append("\(rule.condition.includeKeywords.count) 个包含词")
    }
    if !rule.condition.regularExpressions.isEmpty {
      parts.append("\(rule.condition.regularExpressions.count) 条正则")
    }
    return parts.isEmpty ? "匹配全部消息" : parts.joined(separator: " · ")
  }

  private var actionSummary: String {
    rule.actions.map { action in
      switch action {
      case .capture: return "捕捉"
      case .suppress: return "抑制"
      case .addTag(let name): return "标签：\(name)"
      case .localAlert: return "本地提醒"
      case .enqueueSummary: return "排队摘要"
      case .invokeScript: return "调用脚本"
      }
    }.joined(separator: " · ")
  }

  private func copyRuleSummary() {
    let text = "\(rule.name)\n优先级 \(rule.priority) · \(conditionSummary)\n\(actionSummary)"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

private struct MessageRuleEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var model: AppModel
  @State private var draft = MessageRuleDraft()
  @State private var isSaving = false

  private let alertSeverities: [MessageRuleAlertSeverity] = [
    .information, .warning, .critical,
  ]

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("新建监控规则")
          .font(.title2.weight(.semibold))
        Spacer()
        Button("取消") { dismiss() }
      }
      .padding(22)
      Divider()

      Form {
        Section("基本信息") {
          TextField("规则名称", text: $draft.name)
          Stepper("优先级：\(draft.priority)", value: $draft.priority, in: -1_000...1_000)
          Toggle("启用", isOn: $draft.isEnabled)
        }
        Section("匹配条件") {
          TextField("群聊，多个用逗号分隔", text: $draft.groups)
          TextField("发送者，多个用逗号分隔", text: $draft.senders)
          TextField("包含关键词", text: $draft.includeKeywords)
          TextField("排除关键词", text: $draft.excludeKeywords)
          TextField("正则表达式，每行一条", text: $draft.regularExpressions, axis: .vertical)
            .lineLimit(2...5)
        }
        Section("动作") {
          Toggle("进入重点捕捉", isOn: $draft.capture)
          Toggle("在普通信息流中抑制", isOn: $draft.suppress)
          TextField("添加标签（可选）", text: $draft.tagName)
          Picker("本地提醒", selection: $draft.alertSeverity) {
            Text("不提醒").tag(nil as MessageRuleAlertSeverity?)
            ForEach(alertSeverities, id: \.rawValue) { severity in
              Text(severity.localizedTitle).tag(Optional(severity))
            }
          }
        }
      }
      .formStyle(.grouped)

      Divider()
      HStack {
        if isSaving {
          ProgressView()
            .controlSize(.small)
        }
        Spacer()
        Button("保存") {
          isSaving = true
          Task {
            let saved = await model.saveMessageRule(draft)
            isSaving = false
            if saved { dismiss() }
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          isSaving || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
      }
      .padding(16)
    }
    .frame(width: 620, height: 680)
  }
}

struct DiagnosticsWorkspaceView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    WorkspacePage(title: "运行诊断", subtitle: "采集链路、存储与已知覆盖边界") {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          diagnosticRow(
            title: "企业微信进程",
            value: model.doctorReport?.weChatRunning == true ? "运行中" : "未运行",
            symbol: "bubble.left.and.bubble.right"
          )
          Divider()
          diagnosticRow(
            title: "通知数据库",
            value: model.doctorReport?.notificationDatabaseReadable == true ? "可读取" : "需要授权",
            symbol: "bell.badge"
          )
          Divider()
          diagnosticRow(
            title: "本地消息库",
            value: messageStoreStatus,
            symbol: "externaldrive"
          )
          Divider()
          diagnosticRow(
            title: "全文搜索",
            value: model.messageStoreCapabilities?.fullTextSearchAvailable == true
              ? "FTS5 已启用" : "使用兼容查询",
            symbol: "magnifyingglass"
          )

          GroupBox {
            Label(
              "wxFomo 只能量化系统实际投递并成功解码的通知，不能测量企业微信群真实消息总量或推导完整率。",
              systemImage: "exclamationmark.shield"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.top, 24)
        }
        .padding(22)
      }
    }
  }

  private var messageStoreStatus: String {
    if let error = model.messageStoreError { return "异常：\(error)" }
    guard let capabilities = model.messageStoreCapabilities else { return "不可用" }
    return "schema \(capabilities.schemaVersion) · \(capabilities.journalMode.uppercased())"
  }

  private func diagnosticRow(title: String, value: String, symbol: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .foregroundStyle(.secondary)
        .frame(width: 20)
      Text(title)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
    .padding(.vertical, 12)
  }
}

struct AnalysisComposerSnapshot: Identifiable, Sendable {
  let id = UUID()
  let messages: [MessageEvent]
  let rangeTitle: String
}

struct AnalysisComposerView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var model: AppModel
  let snapshot: AnalysisComposerSnapshot
  @State private var mode: AIAnalysisMode = .digest
  @State private var customInstructions = ""
  @State private var selectedProviderID: String?
  @State private var isSubmitting = false
  @State private var detectedAddressCount: Int?

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("创建 AI 分析")
            .font(.title2.weight(.semibold))
          Text(snapshot.rangeTitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("取消") { dismiss() }
      }
      .padding(22)
      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Label(
            "只分析打开窗口时已显示的 \(snapshot.messages.count) 条消息，不会自动包含之后到达或尚未加载的消息。",
            systemImage: "scope"
          )
          .font(.callout.weight(.medium))

          Text("输入来自 wxFomo 已采集的本地通知消息，不代表企业微信群完整信息流。提交后消息范围会被冻结，后台任务只读取这份快照。")
            .font(.caption)
            .foregroundStyle(.secondary)

          if let detectedAddressCount {
            Label(
              "本地检测到 \(detectedAddressCount) 个 0x / Solana 地址格式，分析结果会附带邻近消息上下文。",
              systemImage: "link"
            )
            .font(.caption)
            .foregroundStyle(detectedAddressCount > 0 ? .primary : .secondary)
          } else {
            HStack(spacing: 7) {
              ProgressView()
                .controlSize(.small)
              Text("正在后台识别 0x / Solana 地址…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }

          if model.providerConfigurations.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
              Label("需要先配置一个 AI 服务", systemImage: "key")
                .font(.headline)
              Button {
                dismiss()
                model.workspaceSelection = .providers
              } label: {
                Label("前往 AI 服务", systemImage: "arrow.right")
              }
            }
          } else {
            Picker("AI 服务", selection: $selectedProviderID) {
              ForEach(model.providerConfigurations) { configuration in
                Text("\(configuration.displayName) · \(configuration.model)")
                  .tag(Optional(configuration.configurationID))
              }
            }

            Picker("分析方式", selection: $mode) {
              ForEach(AIAnalysisMode.allCases, id: \.self) { mode in
                Label(mode.localizedTitle, systemImage: mode.systemImage).tag(mode)
              }
            }

            if mode == .custom {
              VStack(alignment: .leading, spacing: 6) {
                Text("分析要求")
                  .font(.callout.weight(.medium))
                TextEditor(text: $customInstructions)
                  .font(.body)
                  .scrollContentBackground(.hidden)
                  .padding(6)
                  .frame(minHeight: 110, maxHeight: 180)
                  .background(Color(nsColor: .textBackgroundColor))
                  .overlay {
                    RoundedRectangle(cornerRadius: 6)
                      .stroke(Color(nsColor: .separatorColor))
                  }
                Text(
                  "\(customInstructions.count) / \(AIAnalysisRequest.maximumCustomInstructionCharacters)"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(
                  customInstructions.count > AIAnalysisRequest.maximumCustomInstructionCharacters
                    ? .red : .secondary
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
              }
            }
          }

          if let error = model.workspaceStoreError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.red)
              .textSelection(.enabled)
          }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      Divider()
      HStack {
        if isSubmitting {
          ProgressView()
            .controlSize(.small)
        }
        Spacer()
        Button {
          submit()
        } label: {
          Label("创建分析任务", systemImage: "sparkles")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSubmit)
      }
      .padding(16)
    }
    .frame(width: 540)
    .frame(minHeight: 430, maxHeight: 590)
    .onAppear(perform: ensureProviderSelection)
    .onChange(of: model.providerConfigurations) { ensureProviderSelection() }
    .task(id: snapshot.id) {
      await detectAddresses()
    }
  }

  private var canSubmit: Bool {
    guard !isSubmitting,
      !snapshot.messages.isEmpty,
      snapshot.messages.count <= AIAnalysisRequest.maximumMessageCount,
      selectedProviderID != nil
    else { return false }

    if mode == .custom {
      let instructions = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
      return !instructions.isEmpty
        && customInstructions.count <= AIAnalysisRequest.maximumCustomInstructionCharacters
    }
    return true
  }

  private func detectAddresses() async {
    let events = snapshot.messages
    let count = await Task.detached(priority: .utility) {
      CryptoAddressDetector.detect(
        in: events.map(AIAnalysisSourceMessage.init(event:))
      ).count
    }.value
    guard !Task.isCancelled else { return }
    detectedAddressCount = count
  }

  private func ensureProviderSelection() {
    if let selectedProviderID,
      model.providerConfigurations.contains(where: {
        $0.configurationID == selectedProviderID
      })
    {
      return
    }
    if let defaultProviderID = model.defaultProviderID,
      model.providerConfigurations.contains(where: {
        $0.configurationID == defaultProviderID
      })
    {
      selectedProviderID = defaultProviderID
    } else {
      selectedProviderID = model.providerConfigurations.first?.configurationID
    }
  }

  private func submit() {
    guard canSubmit else { return }
    isSubmitting = true
    Task {
      let submitted = await model.enqueueAnalysis(
        mode: mode,
        customInstructions: mode == .custom ? customInstructions : nil,
        providerID: selectedProviderID,
        messages: snapshot.messages
      )
      isSubmitting = false
      if submitted {
        dismiss()
      }
    }
  }
}

private extension AIAnalysisJobState {
  var workspaceTitle: String {
    switch self {
    case .pending: return "排队中"
    case .running: return "分析中"
    case .retryWait: return "等待重试"
    case .succeeded: return "已完成"
    case .failed: return "失败"
    case .cancelled: return "已取消"
    }
  }

  var workspaceSymbol: String {
    switch self {
    case .pending: return "clock"
    case .running: return "sparkles"
    case .retryWait: return "arrow.clockwise"
    case .succeeded: return "checkmark.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    case .cancelled: return "xmark.circle"
    }
  }

  var workspaceColor: Color {
    switch self {
    case .pending: return .secondary
    case .running: return .accentColor
    case .retryWait: return .orange
    case .succeeded: return .green
    case .failed: return .red
    case .cancelled: return .secondary
    }
  }
}

private extension AIEpistemicStatus {
  var workspaceTitle: String {
    switch self {
    case .fact: return "事实"
    case .inference: return "推测"
    case .uncertain: return "不确定"
    }
  }

  var workspaceSymbol: String {
    switch self {
    case .fact: return "checkmark.seal"
    case .inference: return "arrow.triangle.branch"
    case .uncertain: return "questionmark.circle"
    }
  }

  var workspaceColor: Color {
    switch self {
    case .fact: return .green
    case .inference: return .orange
    case .uncertain: return .secondary
    }
  }
}

private extension AIAnalysisFindingCategory {
  var workspaceTitle: String {
    switch self {
    case .keyClaim: return "关键信息"
    case .actionItem: return "待办"
    case .deadline: return "时间点"
    case .risk: return "风险"
    case .opportunity: return "机会"
    case .disagreement: return "分歧"
    case .openQuestion: return "待确认"
    }
  }

  var workspaceSymbol: String {
    switch self {
    case .keyClaim: return "quote.opening"
    case .actionItem: return "checklist"
    case .deadline: return "calendar.badge.clock"
    case .risk: return "exclamationmark.triangle"
    case .opportunity: return "lightbulb"
    case .disagreement: return "arrow.left.arrow.right"
    case .openQuestion: return "questionmark.bubble"
    }
  }
}

private extension AIAnalysisValidationWarning {
  var workspaceTitle: String {
    switch self {
    case .unknownSourceReferenceRemoved: return "已移除无法对应到冻结消息的来源引用"
    case .uncitedClaimDowngraded: return "无来源结论已降级为不确定"
    case .uncitedSummary: return "摘要没有可验证的来源引用"
    case .uncitedTopic: return "至少一个主题没有可验证的来源引用"
    case .unknownCryptoAddressRemoved: return "已移除不在本地检测证据中的模型地址"
    case .uncitedCryptoContext: return "至少一个地址的 AI 上下文没有可验证引用"
    case .missingCryptoContext: return "至少一个地址没有收到 AI 上下文概括"
    }
  }
}

private extension AIProviderConnectionTestStatus {
  var workspaceSymbol: String {
    switch self {
    case .success: return "checkmark.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .failure: return "xmark.circle.fill"
    }
  }

  var workspaceColor: Color {
    switch self {
    case .success: return .green
    case .warning: return .orange
    case .failure: return .red
    }
  }
}

private extension AIProviderConnectionTestResult {
  func workspaceMessage(model: String) -> String {
    switch code {
    case .catalogVerified:
      return "鉴权和模型目录正常，已找到 \(model)；未执行生成"
    case .catalogUnavailable:
      return "上游不提供标准模型目录，无法无费用确认模型；不代表生成不可用"
    case .catalogEmpty:
      return "鉴权端点可达，但模型目录为空；未执行生成"
    case .modelNotFound:
      return "鉴权正常，但模型目录中未找到 \(model)"
    case .authenticationFailed:
      return "鉴权失败\(httpStatusSuffix)"
    case .httpFailure:
      return "模型目录请求失败\(httpStatusSuffix)"
    case .credentialUnavailable:
      return "本服务尚未配置 API Key"
    case .invalidConfiguration:
      return "服务 URL 或协议配置无效"
    case .transportFailure:
      return "网络连接失败"
    case .responseTooLarge:
      return "模型目录响应过大，已停止读取"
    case .invalidResponse:
      return "上游返回的模型目录格式无法识别"
    }
  }

  private var httpStatusSuffix: String {
    httpStatusCode.map { "（HTTP \($0)）" } ?? ""
  }
}

private extension CryptoAddressRoleHint {
  var workspaceTitle: String {
    switch self {
    case .contractOrToken: return "合约或代币提示"
    case .wallet: return "钱包提示"
    case .ambiguous: return "角色有歧义"
    case .unknown: return "角色未确定"
    }
  }
}

private extension MessageKind {
  var workspaceTitle: String {
    switch self {
    case .text: return "文字"
    case .media: return "媒体"
    case .system: return "系统"
    case .unknown: return "未知"
    }
  }
}

struct FlowLayout: Layout {
  let spacing: CGFloat

  struct Arrangement {
    let size: CGSize
    let points: [CGPoint]
  }

  struct Cache {
    var availableWidth: CGFloat?
    var subviewCount = 0
    var arrangement: Arrangement?
  }

  func makeCache(subviews: Subviews) -> Cache {
    Cache(availableWidth: nil, arrangement: nil)
  }

  func updateCache(_ cache: inout Cache, subviews: Subviews) {
    cache = Cache(availableWidth: nil, arrangement: nil)
  }

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout Cache
  ) -> CGSize {
    arrangement(proposal: proposal, subviews: subviews, cache: &cache).size
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout Cache
  ) {
    let arrangement = arrangement(
      proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
      subviews: subviews,
      cache: &cache
    )
    for (index, point) in arrangement.points.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
        anchor: .topLeading,
        proposal: .unspecified
      )
    }
  }

  private func arrangement(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout Cache
  ) -> Arrangement {
    let availableWidth = proposal.width ?? .infinity
    if cache.availableWidth == availableWidth,
      cache.subviewCount == subviews.count,
      let cached = cache.arrangement
    {
      return cached
    }

    var points: [CGPoint] = []
    var origin = CGPoint.zero
    var rowHeight: CGFloat = 0
    var usedWidth: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if origin.x > 0, origin.x + size.width > availableWidth {
        origin.x = 0
        origin.y += rowHeight + spacing
        rowHeight = 0
      }
      points.append(origin)
      usedWidth = max(usedWidth, origin.x + size.width)
      rowHeight = max(rowHeight, size.height)
      origin.x += size.width + spacing
    }

    let result = Arrangement(
      size: CGSize(width: min(usedWidth, availableWidth), height: origin.y + rowHeight),
      points: points
    )
    cache.availableWidth = availableWidth
    cache.subviewCount = subviews.count
    cache.arrangement = result
    return result
  }
}

struct WorkspacePage<Content: View>: View {
  let title: String
  let subtitle: String
  @ViewBuilder let content: Content

  init(
    title: String,
    subtitle: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.title2.weight(.semibold))
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 22)
      .padding(.vertical, 16)
      Divider()
      content
    }
  }
}
