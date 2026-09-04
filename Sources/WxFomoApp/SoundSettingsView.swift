import SwiftUI
import WxFomoCore

struct SoundSettingsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var editingRule: NotificationSoundRule?
  @State private var showsResetConfirmation = false
  @State private var currentPage = 1

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      List {
        Section("总控") {
          Toggle("启用声音与语音提醒", isOn: masterEnabledBinding)

          LabeledContent("总音量") {
            HStack(spacing: 10) {
              Image(systemName: "speaker.wave.1")
                .foregroundStyle(.secondary)
              Slider(value: masterVolumeBinding, in: 0...1)
                .frame(width: 220)
              Text(model.soundConfiguration.masterVolume.formatted(.percent.precision(.fractionLength(0))))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
            }
          }

          Toggle("应用在前台时也播放", isOn: playWhileActiveBinding)

          Picker("连续声音最小间隔", selection: minimumIntervalBinding) {
            ForEach(Self.minimumIntervals, id: \.self) { interval in
              Text(interval == 0 ? "不限制" : "\(interval.formatted()) 秒").tag(interval)
            }
          }

          LabeledContent("临时静音") {
            HStack(spacing: 10) {
              if let mutedUntil = model.soundConfiguration.mutedUntil,
                mutedUntil > Date()
              {
                Text("至 \(mutedUntil.formatted(date: .omitted, time: .shortened))")
                  .foregroundStyle(.secondary)
                Button("恢复声音") { model.muteSounds(for: 0) }
              } else {
                Button("静音 1 小时") { model.muteSounds(for: 60 * 60) }
                Button("静音到明天") { model.muteSounds(for: secondsUntilTomorrow) }
              }
            }
          }
        }

        Section("语音播报") {
          LabeledContent("当前语音") {
            Text(configuredSpeechTitle)
              .foregroundStyle(.secondary)
          }

          if model.soundConfiguration.speech.provider == .volcengineSeed {
            LabeledContent("服务状态") {
              Label(
                model.isSpeechAPIKeyConfigured ? "火山语音已配置" : "缺少火山 API Key，将使用系统回退",
                systemImage: model.isSpeechAPIKeyConfigured
                  ? "checkmark.circle.fill"
                  : "exclamationmark.triangle.fill"
              )
              .foregroundStyle(model.isSpeechAPIKeyConfigured ? .green : .orange)
            }
          }

          Button {
            model.workspaceSelection = .providers
          } label: {
            Label("前往配置中心", systemImage: "gearshape.2")
          }
        }

        Section {
          if model.soundConfiguration.rules.isEmpty {
            ContentUnavailableView {
              Label("还没有提醒规则", systemImage: "speaker.slash")
            } description: {
              Text("添加规则后，可以按事件、群聊和发送者播放音效或语音。")
            }
            .frame(maxWidth: .infinity, minHeight: 180)
          } else {
            ForEach(pagedRules) { rule in
              SoundRuleRow(rule: rule, onEdit: { editingRule = rule })
                .environmentObject(model)
            }
            PaginationBar(
              totalCount: model.soundConfiguration.rules.count,
              currentPage: $currentPage,
              showsTopDivider: false
            )
          }
        } header: {
          HStack {
            Text("条件提醒")
            Spacer()
            Text("高优先级先播放，同优先级按 群+发送者 > 发送者 > 群 > 全局")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .textCase(nil)
        }
      }
      .listStyle(.inset)
    }
    .sheet(item: $editingRule) { rule in
      SoundRuleEditorView(rule: rule) { savedRule in
        model.saveSoundRule(savedRule)
        editingRule = nil
      }
      .environmentObject(model)
    }
    .confirmationDialog(
      "恢复默认提醒规则？",
      isPresented: $showsResetConfirmation
    ) {
      Button("恢复默认", role: .destructive) { model.resetSoundConfiguration() }
      Button("取消", role: .cancel) {}
    } message: {
      Text("自定义的群聊和发送者提醒规则会被移除。")
    }
  }

  private var pagedRules: [NotificationSoundRule] {
    model.soundConfiguration.rules.pageItems(page: currentPage)
  }

  private var header: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("声音与提醒")
          .font(.title2.weight(.semibold))
        Text("按事件、群聊和发送者区分音效与语音")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if let status = model.soundStatusText {
        Text(status)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Button {
        showsResetConfirmation = true
      } label: {
        Image(systemName: "arrow.counterclockwise")
      }
      .help("恢复默认提醒规则")

      Button {
        editingRule = Self.newRule()
      } label: {
        Label("添加规则", systemImage: "plus")
      }
      .buttonStyle(.borderedProminent)
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 16)
  }

  private var masterEnabledBinding: Binding<Bool> {
    Binding(
      get: { model.soundConfiguration.isEnabled },
      set: model.setSoundEnabled
    )
  }

  private var masterVolumeBinding: Binding<Double> {
    Binding(
      get: { model.soundConfiguration.masterVolume },
      set: model.setSoundMasterVolume
    )
  }

  private var playWhileActiveBinding: Binding<Bool> {
    Binding(
      get: { model.soundConfiguration.playWhileAppIsActive },
      set: model.setSoundPlayWhileActive
    )
  }

  private var minimumIntervalBinding: Binding<TimeInterval> {
    Binding(
      get: { model.soundConfiguration.minimumInterval },
      set: model.setSoundMinimumInterval
    )
  }

  private var configuredSpeechTitle: String {
    let speech = model.soundConfiguration.speech
    guard speech.provider == .volcengineSeed else { return speech.provider.localizedTitle }
    let voice = NotificationSpeechVoiceChoice(rawValue: speech.voiceID)?.localizedTitle
      ?? speech.voiceID
    return "\(speech.provider.localizedTitle) · \(voice)"
  }

  private var secondsUntilTomorrow: TimeInterval {
    let calendar = Calendar.current
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    let start = calendar.startOfDay(for: tomorrow)
    return max(start.timeIntervalSinceNow, 60)
  }

  private static let minimumIntervals: [TimeInterval] = [0, 0.5, 1, 1.5, 2, 5]

  private static func newRule() -> NotificationSoundRule {
    NotificationSoundRule(
      id: UUID().uuidString.lowercased(),
      name: "新的提醒规则",
      eventKind: .cryptoAddress,
      outputMode: .speech,
      soundName: NotificationSoundChoice.ping.rawValue,
      volume: 0.8,
      speechAnnouncement: NotificationSpeechAnnouncement(
        text: NotificationSoundEventKind.cryptoAddress.defaultSpeechText
      ),
      priority: 50,
      cooldownInterval: 10 * 60
    )
  }
}

private struct SoundRuleRow: View {
  @EnvironmentObject private var model: AppModel
  let rule: NotificationSoundRule
  let onEdit: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Toggle(
        "",
        isOn: Binding(
          get: { rule.isEnabled },
          set: { model.setSoundRuleEnabled(rule, isEnabled: $0) }
        )
      )
      .labelsHidden()

      Image(systemName: rule.eventKind.systemImage)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(rule.isEnabled ? WxFomoTheme.signal : .secondary)
        .frame(width: 28, height: 28)

      VStack(alignment: .leading, spacing: 3) {
        Text(rule.name)
          .font(.callout.weight(.semibold))
          .lineLimit(1)
        Text("\(rule.eventKind.localizedTitle) · \(rule.scopeDescription)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 12)

      Text("优先级 \(rule.priority)")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.tertiary)

      Text(rule.outputDescription)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(width: 150, alignment: .trailing)

      Button {
        model.previewSoundRule(rule)
      } label: {
        Image(systemName: "play.fill")
      }
      .buttonStyle(.borderless)
      .help("试听 \(rule.name)")

      Button(action: onEdit) {
        Image(systemName: "pencil")
      }
      .buttonStyle(.borderless)
      .help("编辑规则")

      Menu {
        Button("复制规则") {
          var copy = rule
          copy.id = UUID().uuidString.lowercased()
          copy.name += " 副本"
          model.saveSoundRule(copy)
        }
        Divider()
        Button("删除规则", role: .destructive) {
          model.deleteSoundRule(rule)
        }
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.borderlessButton)
      .frame(width: 28)
      .help("更多规则操作")
    }
    .padding(.vertical, 6)
  }
}

private struct SoundRuleEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var model: AppModel
  @State private var draft: NotificationSoundRule
  @State private var groupsText: String
  @State private var sendersText: String

  let onSave: (NotificationSoundRule) -> Void

  init(
    rule: NotificationSoundRule,
    onSave: @escaping (NotificationSoundRule) -> Void
  ) {
    _draft = State(initialValue: rule.normalized)
    _groupsText = State(initialValue: rule.groups.joined(separator: "，"))
    _sendersText = State(initialValue: rule.senders.joined(separator: "，"))
    self.onSave = onSave
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("配置提醒规则")
          .font(.title2.weight(.semibold))
        Spacer()
        Button("取消") { dismiss() }
      }
      .padding(22)

      Divider()

      Form {
        Section("基本信息") {
          TextField("规则名称", text: $draft.name)
          Toggle("启用", isOn: $draft.isEnabled)
          Picker("触发事件", selection: $draft.eventKind) {
            ForEach(NotificationSoundEventKind.allCases) { kind in
              Label(kind.localizedTitle, systemImage: kind.systemImage).tag(kind)
            }
          }
        }

        Section("匹配范围") {
          TextField("群聊，留空表示全部群", text: $groupsText)
          if !model.groups.isEmpty {
            Menu("从监听群选择") {
              ForEach(model.groups, id: \.self) { group in
                Button(group) { append(group, to: &groupsText) }
              }
            }
          }

          TextField("发送者，留空表示任何人", text: $sendersText)
          if !model.knownSoundSenderNames.isEmpty {
            Menu("从已识别发送者选择") {
              ForEach(model.knownSoundSenderNames, id: \.self) { sender in
                Button(sender) { append(sender, to: &sendersText) }
              }
            }
          }

          if !parsedTerms(sendersText).isEmpty {
            Label(
              "发送者按通知中的群昵称匹配；同名或改名可能导致误匹配。",
              systemImage: "person.crop.circle.badge.questionmark"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }

        Section("播放") {
          Picker("提示方式", selection: outputModeBinding) {
            ForEach(NotificationSoundOutputMode.allCases) { mode in
              Text(mode.localizedTitle).tag(mode)
            }
          }

          if draft.effectiveOutputMode.includesSound {
            Picker("声音", selection: $draft.soundName) {
              ForEach(NotificationSoundChoice.allCases) { sound in
                Text(sound.localizedTitle).tag(sound.rawValue)
              }
            }

            LabeledContent("音效音量") {
              HStack(spacing: 10) {
                Slider(value: $draft.volume, in: 0...1)
                  .frame(width: 230)
                Text(draft.volume.formatted(.percent.precision(.fractionLength(0))))
                  .font(.caption.monospacedDigit())
                  .frame(width: 42, alignment: .trailing)
              }
            }
          }

          if draft.effectiveOutputMode.includesSpeech {
            TextField("播报文字", text: speechTextBinding)

            LabeledContent("语音音量") {
              HStack(spacing: 10) {
                Slider(value: speechVolumeBinding, in: 0...1)
                  .frame(width: 230)
                Text(speechVolumeBinding.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                  .font(.caption.monospacedDigit())
                  .frame(width: 42, alignment: .trailing)
              }
            }

            LabeledContent("语速") {
              HStack(spacing: 10) {
                Slider(value: speechRateBinding, in: 0.5...2, step: 0.05)
                  .frame(width: 230)
                Text("\(speechRateBinding.wrappedValue.formatted(.number.precision(.fractionLength(2))))×")
                  .font(.caption.monospacedDigit())
                  .frame(width: 42, alignment: .trailing)
              }
            }
          }

          LabeledContent("试听") {
            Button {
              model.previewSoundRule(draft)
            } label: {
              Label("播放当前设置", systemImage: "play.fill")
            }
          }

          Picker("同一对象冷却", selection: $draft.cooldownInterval) {
            ForEach(Self.cooldownOptions, id: \.seconds) { option in
              Text(option.title).tag(option.seconds)
            }
          }

          Stepper("优先级：\(draft.priority)", value: $draft.priority, in: 0...1_000)
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Text("同一条消息只执行命中的最高优先级规则")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("保存") { save() }
          .buttonStyle(.borderedProminent)
          .disabled(!canSave)
      }
      .padding(16)
    }
    .frame(width: 640, height: 700)
  }

  private func save() {
    draft.groups = parsedTerms(groupsText)
    draft.senders = parsedTerms(sendersText)
    onSave(draft)
  }

  private var canSave: Bool {
    guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }
    return !draft.effectiveOutputMode.includesSpeech
      || !speechTextBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var outputModeBinding: Binding<NotificationSoundOutputMode> {
    Binding(
      get: { draft.effectiveOutputMode },
      set: { draft.outputMode = $0 }
    )
  }

  private var speechTextBinding: Binding<String> {
    Binding(
      get: { draft.effectiveSpeechAnnouncement.text },
      set: { newValue in
        var announcement = draft.effectiveSpeechAnnouncement
        announcement.text = newValue
        draft.speechAnnouncement = announcement
      }
    )
  }

  private var speechVolumeBinding: Binding<Double> {
    Binding(
      get: { draft.effectiveSpeechAnnouncement.volume },
      set: { newValue in
        var announcement = draft.effectiveSpeechAnnouncement
        announcement.volume = newValue
        draft.speechAnnouncement = announcement
      }
    )
  }

  private var speechRateBinding: Binding<Double> {
    Binding(
      get: { draft.effectiveSpeechAnnouncement.rate },
      set: { newValue in
        var announcement = draft.effectiveSpeechAnnouncement
        announcement.rate = newValue
        draft.speechAnnouncement = announcement
      }
    )
  }

  private func append(_ value: String, to text: inout String) {
    var values = parsedTerms(text)
    guard !values.contains(where: { $0.localizedCaseInsensitiveCompare(value) == .orderedSame })
    else { return }
    values.append(value)
    text = values.joined(separator: "，")
  }

  private func parsedTerms(_ value: String) -> [String] {
    value
      .components(separatedBy: CharacterSet(charactersIn: ",，\n"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private static let cooldownOptions: [(title: String, seconds: TimeInterval)] = [
    ("不冷却", 0),
    ("10 秒", 10),
    ("30 秒", 30),
    ("1 分钟", 60),
    ("5 分钟", 5 * 60),
    ("10 分钟", 10 * 60),
    ("30 分钟", 30 * 60),
    ("1 小时", 60 * 60),
  ]
}

private extension NotificationSoundEventKind {
  var localizedTitle: String {
    switch self {
    case .newMessage: return "普通新消息"
    case .capturedSignal: return "重点信号"
    case .cryptoAddress: return "CA 出现"
    case .crossGroupAddress: return "跨群 CA"
    case .alertInformation: return "提示提醒"
    case .alertWarning: return "警告提醒"
    case .alertCritical: return "严重提醒"
    case .analysisCompleted: return "分析完成"
    case .listenerIssue: return "监听异常"
    }
  }

  var systemImage: String {
    switch self {
    case .newMessage: return "message"
    case .capturedSignal: return "scope"
    case .cryptoAddress: return "number"
    case .crossGroupAddress: return "point.3.connected.trianglepath.dotted"
    case .alertInformation: return "info.circle"
    case .alertWarning: return "exclamationmark.triangle"
    case .alertCritical: return "exclamationmark.octagon.fill"
    case .analysisCompleted: return "checkmark.circle"
    case .listenerIssue: return "waveform.path.ecg"
    }
  }
}

private extension NotificationSoundRule {
  var scopeDescription: String {
    switch (groups.isEmpty, senders.isEmpty) {
    case (true, true): return "全部群和发送者"
    case (false, true): return groups.count == 1 ? groups[0] : "\(groups.count) 个群"
    case (true, false): return senders.count == 1 ? senders[0] : "\(senders.count) 位发送者"
    case (false, false):
      let groupText = groups.count == 1 ? groups[0] : "\(groups.count) 个群"
      let senderText = senders.count == 1 ? senders[0] : "\(senders.count) 位发送者"
      return "\(groupText) · \(senderText)"
    }
  }

  var outputDescription: String {
    switch effectiveOutputMode {
    case .sound:
      return NotificationSoundChoice(rawValue: soundName)?.localizedTitle ?? soundName
    case .speech:
      return "语音：\(effectiveSpeechAnnouncement.text)"
    case .soundAndSpeech:
      return "音效 + \(effectiveSpeechAnnouncement.text)"
    }
  }
}

private extension NotificationSoundOutputMode {
  var localizedTitle: String {
    switch self {
    case .sound: return "音效"
    case .speech: return "语音"
    case .soundAndSpeech: return "音效 + 语音"
    }
  }
}

extension NotificationSpeechProvider {
  var localizedTitle: String {
    switch self {
    case .volcengineSeed: return "火山语音"
    case .system: return "系统中文语音"
    }
  }
}
