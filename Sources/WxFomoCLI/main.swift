import AppKit
import Foundation
import WxFomoCore

private enum CLIError: LocalizedError {
  case usage(String)

  var errorDescription: String? {
    switch self {
    case .usage(let message):
      return message
    }
  }
}

private struct CLI {
  private let reader = WeChatAccessibilityReader()
  private let ocrReader = WeChatOCRReader()
  private let notificationReader = NotificationDatabaseReader()
  private let messageParser = MessageParser()

  func run(arguments: [String]) async throws {
    guard let command = arguments.first else {
      printUsage()
      return
    }

    switch command {
    case "doctor":
      doctor(arguments: Array(arguments.dropFirst()))
    case "probe":
      try probe(arguments: Array(arguments.dropFirst()))
    case "ocr-probe":
      try await ocrProbe(arguments: Array(arguments.dropFirst()))
    case "ocr-inspect":
      try await ocrInspect(arguments: Array(arguments.dropFirst()))
    case "notification-probe":
      try notificationProbe(arguments: Array(arguments.dropFirst()))
    case "notification-dump":
      try notificationDump(arguments: Array(arguments.dropFirst()))
    case "inspect":
      try inspect(arguments: Array(arguments.dropFirst()))
    case "listen":
      try await notificationListen(arguments: Array(arguments.dropFirst()))
    case "ocr-listen":
      try await ocrListen(arguments: Array(arguments.dropFirst()))
    case "help", "--help", "-h":
      printUsage()
    default:
      throw CLIError.usage("未知命令：\(command)；运行 wxfomo help 查看用法")
    }
  }

  private func notificationProbe(arguments: [String]) throws {
    var limit = 10
    var showText = false
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--limit":
        index += 1
        let raw = try value(at: index, in: arguments, option: "--limit")
        guard let parsed = Int(raw), parsed > 0 else {
          throw CLIError.usage("--limit 必须是正整数")
        }
        limit = min(parsed, 100)
      case "--show-text":
        showText = true
      default:
        throw CLIError.usage("notification-probe 不支持参数：\(arguments[index])")
      }
      index += 1
    }

    let records = try notificationReader.recentRecords(limit: limit)
    print("最近微信通知：\(records.count)")
    for record in records {
      print(
        "rowid=\(record.rowID) delivered=\(ISO8601DateFormatter().string(from: record.deliveredAt))"
      )
      for (name, value) in [
        ("title", record.title), ("subtitle", record.subtitle), ("body", record.body),
      ] {
        if showText {
          print("  \(name)=\(value)")
        } else {
          print("  \(name)=<redacted length=\(value.count) hash=\(StableHash.hex(value))>")
        }
      }
    }
    if !showText {
      print("文本默认隐藏；只在你确认终端输出安全时使用 --show-text。")
    }
  }

  private func ocrInspect(arguments: [String]) async throws {
    var group: String?
    var showText = false
    var rowLimit = 12
    var index = 0

    while index < arguments.count {
      switch arguments[index] {
      case "--group":
        index += 1
        group = try value(at: index, in: arguments, option: "--group")
      case "--show-text":
        showText = true
      case "--rows":
        index += 1
        let raw = try value(at: index, in: arguments, option: "--rows")
        guard let parsed = Int(raw), parsed > 0 else {
          throw CLIError.usage("--rows 必须是正整数")
        }
        rowLimit = min(parsed, 50)
      default:
        throw CLIError.usage("ocr-inspect 不支持参数：\(arguments[index])")
      }
      index += 1
    }

    guard let group, !group.isEmpty else {
      throw CLIError.usage("ocr-inspect 需要 --group \"群名\"")
    }
    let snapshot = try await ocrReader.snapshot(group: group)
    print("群聊：\(showText ? group : "<redacted hash=\(StableHash.hex(group))>")")
    print("窗口：\(snapshot.windowID)")
    print("匹配：\(snapshot.confidence.rawValue)")
    print("OCR 文本行：\(snapshot.recognizedLines.count)")
    let rows = snapshot.rows.suffix(rowLimit)
    print("候选消息行：\(rows.count)")
    for (rowIndex, row) in rows.enumerated() {
      let parsed = messageParser.parse(row: row, group: group)
      let senderConfidence = parsed?.senderConfidence.rawValue ?? "ignored"
      let kind = parsed?.kind.rawValue ?? "ignored"
      print("row[\(rowIndex)] labels=\(row.labels.count) sender=\(senderConfidence) type=\(kind)")
      for label in row.labels {
        if showText {
          print("  \(label)")
        } else {
          print("  <redacted length=\(label.count) hash=\(StableHash.hex(label))>")
        }
      }
    }
    if !showText {
      print("文本默认隐藏；只在你确认终端输出安全时使用 --show-text。")
    }
  }

  private func ocrProbe(arguments: [String]) async throws {
    var maximumLines = 100
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--lines":
        index += 1
        let raw = try value(at: index, in: arguments, option: "--lines")
        guard let parsed = Int(raw), parsed > 0 else {
          throw CLIError.usage("--lines 必须是正整数")
        }
        maximumLines = min(parsed, 500)
      default:
        throw CLIError.usage("ocr-probe 不支持参数：\(arguments[index])")
      }
      index += 1
    }

    let windows = try await ocrReader.probe(maximumLinesPerWindow: maximumLines)
    for (windowIndex, window) in windows.enumerated() {
      let title = window.title.map { "len=\($0.length) hash=\($0.digest)" } ?? "none"
      print(
        "window[\(windowIndex)] id=\(window.windowID) title=\(title) "
          + "frame=\(Int(window.frame.width))x\(Int(window.frame.height)) lines=\(window.lines.count)"
      )
      for line in window.lines {
        let frame = line.frame
        print(
          String(
            format: "  x=%.3f y=%.3f w=%.3f h=%.3f confidence=%.2f len=%d hash=%@",
            frame.x,
            frame.y,
            frame.width,
            frame.height,
            line.confidence,
            line.text.count,
            StableHash.hex(line.text)
          ))
      }
    }
    print("ocr-probe 在本机识别文本，但不输出任何原始群名、昵称或消息正文。")
  }

  private func probe(arguments: [String]) throws {
    var maximumNodes = 300
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--nodes":
        index += 1
        let raw = try value(at: index, in: arguments, option: "--nodes")
        guard let parsed = Int(raw), parsed > 0 else {
          throw CLIError.usage("--nodes 必须是正整数")
        }
        maximumNodes = min(parsed, 2_000)
      default:
        throw CLIError.usage("probe 不支持参数：\(arguments[index])")
      }
      index += 1
    }

    let windows = try reader.probe(maximumNodesPerWindow: maximumNodes)
    for (windowIndex, window) in windows.enumerated() {
      let title = window.title.map { "len=\($0.length) hash=\($0.digest)" } ?? "none"
      print("window[\(windowIndex)] title=\(title) nodes=\(window.nodes.count)")
      for node in window.nodes {
        let indent = String(repeating: "  ", count: min(node.depth, 12))
        let frame: String
        if let value = node.frame {
          frame = "x=\(Int(value.x)) y=\(Int(value.y)) w=\(Int(value.width)) h=\(Int(value.height))"
        } else {
          frame = "no-frame"
        }
        let labels = node.labels.map { "\($0.length):\($0.digest)" }.joined(separator: ",")
        print("\(indent)\(node.role) children=\(node.childCount) \(frame) labels=[\(labels)]")
      }
    }
    print("probe 不输出任何原始群名、昵称或消息正文。")
  }

  private func doctor(arguments: [String]) {
    let prompt = arguments.contains("--prompt")
    let openSettings = arguments.contains("--open-settings")
    let deep = arguments.contains("--deep")
    if openSettings {
      if let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
      ) {
        NSWorkspace.shared.open(url)
      }
    }
    let report = reader.doctor(promptForPermission: prompt)
    print("微信安装：\(report.weChatInstalled ? "是" : "否")")
    print("微信版本：\(report.weChatVersion ?? "未知")")
    print("微信运行：\(report.weChatRunning ? "是" : "否")")
    print("辅助功能权限：\(report.accessibilityTrusted ? "已授权" : "未授权")")
    print("屏幕捕获权限：\(report.screenCaptureTrusted ? "已授权" : "未授权")")
    let availability = notificationReader.availability()
    switch availability {
    case .readable:
      print("通知数据库：可读取")
    case .missingFile:
      print("通知数据库：文件不存在（\(notificationReader.databaseURL.path)）")
    case .permissionDenied:
      print("通知数据库：被系统拒绝（缺少“完全磁盘访问”权限）")
    case .unreadable(let message):
      print("通知数据库：不可读取（\(message)）")
    }
    if availability != .readable {
      print("通知信息流需要：系统设置 → 隐私与安全性 → 完全磁盘访问，为当前终端或 wxfomo 授权。")
      print("也可以运行：wxfomo doctor --open-settings 直接打开对应设置面板。")
    }
    if !report.accessibilityTrusted {
      print("请到 系统设置 → 隐私与安全性 → 辅助功能，为当前终端或 wxfomo 授权。")
      if !prompt {
        print("也可以运行：wxfomo doctor --prompt")
      }
    }
    if deep {
      let activity = recentWeChatNotificationLogActivity(hours: 2)
      if activity < 0 {
        print("系统日志检查：不可用")
      } else {
        print("最近 2 小时系统收到的微信通知活动：\(activity) 条")
      }
    }
  }

  private func recentWeChatNotificationLogActivity(hours: Int) -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = [
      "show",
      "--last",
      "\(hours)h",
      "--info",
      "--style",
      "compact",
      "--predicate",
      #"process == "usernoted" AND eventMessage CONTAINS[c] "xinWeChat""#,
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
      try process.run()
    } catch {
      return -1
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return -1 }
    let output = String(data: data, encoding: .utf8) ?? ""
    return output.split(separator: "\n").count
  }

  private func notificationDump(arguments: [String]) throws {
    var limit = 10
    var showText = false
    var watchSeconds: Int?
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--limit":
        index += 1
        let raw = try value(at: index, in: arguments, option: "--limit")
        guard let parsed = Int(raw), parsed > 0 else {
          throw CLIError.usage("--limit 必须是正整数")
        }
        limit = min(parsed, 50)
      case "--show-text":
        showText = true
      case "--watch":
        watchSeconds = 60
      case "--duration":
        index += 1
        let raw = try value(at: index, in: arguments, option: "--duration")
        guard let parsed = Int(raw), parsed > 0 else {
          throw CLIError.usage("--duration 必须是正整数")
        }
        watchSeconds = min(parsed, 600)
      default:
        throw CLIError.usage("notification-dump 不支持参数：\(arguments[index])")
      }
      index += 1
    }

    let diagnostics = try notificationReader.diagnostics(sampleLimit: limit)
    switch diagnostics.availability {
    case .missingFile:
      print("通知数据库：文件不存在（\(notificationReader.databaseURL.path)）")
      return
    case .permissionDenied:
      print("通知数据库：被系统拒绝（缺少“完全磁盘访问”权限）")
      print("通知信息流需要：系统设置 → 隐私与安全性 → 完全磁盘访问，为当前终端或 wxfomo 授权。")
      print("也可以运行：wxfomo doctor --open-settings 直接打开对应设置面板。")
      return
    case .unreadable(let message):
      print("通知数据库：不可读取（\(message)）")
      return
    case .readable:
      break
    }

    print("通知数据库：可读取")
    print("数据库文件：\(notificationReader.databaseURL.path)")
    print("表：\(diagnostics.tableNames.joined(separator: ", "))")
    print("各表行数：")
    for rowCount in diagnostics.tableRowCounts {
      print("  \(rowCount.table): \(rowCount.rowCount) 行，最大 rowid \(rowCount.maxRowID)")
    }
    print("各表按 app 的通知数量：")
    for app in diagnostics.tableAppCounts {
      print("  [\(app.table)] \(app.identifier): \(app.count)")
    }
    print("record 总数：\(diagnostics.totalRecordCount)，最大 rowid：\(diagnostics.maxRowID)")
    print("微信记录总数（record 表）：\(diagnostics.weChatRecordCount)")
    let decodedCount = diagnostics.samples.filter(\.decoded).count
    print(
      "最近微信记录样本：\(diagnostics.samples.count)，解码成功 \(decodedCount)，"
        + "失败 \(diagnostics.samples.count - decodedCount)"
    )
    let formatter = ISO8601DateFormatter()
    for sample in diagnostics.samples {
      print(
        "rowid=\(sample.rowID) delivered=\(formatter.string(from: sample.deliveredAt)) "
          + "payload=\(sample.payloadByteCount)B format=\(sample.payloadFormat) "
          + "keys=[\(sample.payloadTopLevelKeys.joined(separator: ","))] "
          + "decoded=\(sample.decoded ? "是" : "否") identifier=\(sample.identifier)"
      )
      for (name, value) in [
        ("title", sample.title), ("subtitle", sample.subtitle), ("body", sample.body),
      ] {
        if showText {
          print("  \(name)=\(value)")
        } else {
          print("  \(name)=<redacted length=\(value.count) hash=\(StableHash.hex(value))>")
        }
      }
    }
    if !showText {
      print("文本默认隐藏；只在你确认终端输出安全时使用 --show-text。")
    }

    if let watchSeconds {
      print("")
      print("开始观察 \(watchSeconds) 秒（每 0.25 秒扫描一次各表新增行，并实时跟踪系统日志）。")
      print("请让本机微信留在后台，然后用另一台设备在群里发测试消息…")
      print("")

      let logProcess = Process()
      logProcess.executableURL = URL(fileURLWithPath: "/usr/bin/log")
      logProcess.arguments = [
        "stream",
        "--info",
        "--style",
        "compact",
        "--predicate",
        #"process == "usernoted" AND eventMessage CONTAINS[c] "xinWeChat""#,
      ]
      let logPipe = Pipe()
      logProcess.standardOutput = logPipe
      logProcess.standardError = Pipe()
      var logStarted = false
      do {
        try logProcess.run()
        logStarted = true
      } catch {
        print("提示：无法启动系统日志流，仅观察数据库。")
      }
      if logStarted {
        logPipe.fileHandleForReading.readabilityHandler = { handle in
          let data = handle.availableData
          if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            for line in text.split(separator: "\n") {
              print("[log] \(line)")
            }
          }
        }
      }

      var watermark = Dictionary(
        uniqueKeysWithValues: diagnostics.tableRowCounts.map { ($0.table, $0.maxRowID) }
      )
      let end = Date().addingTimeInterval(TimeInterval(watchSeconds))
      while Date() < end {
        Thread.sleep(forTimeInterval: 0.25)
        let next = try notificationReader.diagnostics(sampleLimit: 0)
        for rowCount in next.tableRowCounts {
          let previous = watermark[rowCount.table] ?? 0
          guard rowCount.maxRowID > previous else { continue }
          watermark[rowCount.table] = rowCount.maxRowID
          let samples = try notificationReader.newSamples(
            in: rowCount.table,
            after: previous,
            limit: 100
          )
          for sample in samples {
            let marked =
              NotificationDatabaseReader.isWeChatNotificationIdentifier(sample.identifier)
              ? "★微信"
              : "·其他"
            print(
              "[db] [\(sample.table)] \(marked) rowid=\(sample.rowID) app=\(sample.identifier) "
                + "delivered=\(formatter.string(from: sample.deliveredAt)) "
                + "payload=\(sample.payloadByteCount)B format=\(sample.payloadFormat) "
                + "keys=[\(sample.payloadTopLevelKeys.joined(separator: ","))] "
                + "decoded=\(sample.decoded ? "是" : "否")"
            )
            for (name, value) in [
              ("title", sample.title), ("subtitle", sample.subtitle), ("body", sample.body),
            ] {
              if showText {
                print("    \(name)=\(value)")
              } else if sample.decoded {
                print("    \(name)=<redacted length=\(value.count) hash=\(StableHash.hex(value))>")
              }
            }
          }
        }
      }
      if logStarted {
        logProcess.terminate()
        logProcess.waitUntilExit()
        logPipe.fileHandleForReading.readabilityHandler = nil
      }
      print("观察结束。")
    }
  }

  private func inspect(arguments: [String]) throws {
    var group: String?
    var showText = false
    var rowLimit = 8
    var index = 0

    while index < arguments.count {
      switch arguments[index] {
      case "--group":
        index += 1
        group = try value(at: index, in: arguments, option: "--group")
      case "--show-text":
        showText = true
      case "--rows":
        index += 1
        let raw = try value(at: index, in: arguments, option: "--rows")
        guard let parsed = Int(raw), parsed > 0 else {
          throw CLIError.usage("--rows 必须是正整数")
        }
        rowLimit = min(parsed, 50)
      default:
        throw CLIError.usage("inspect 不支持参数：\(arguments[index])")
      }
      index += 1
    }

    guard let group, !group.isEmpty else {
      throw CLIError.usage("inspect 需要 --group \"群名\"")
    }
    let report = try reader.inspect(
      group: group,
      allowSingleGroupFallback: true,
      rowLimit: rowLimit
    )
    print("群聊：\(group)")
    print("窗口：\(report.windowTitle)")
    print("匹配：\(report.confidence.rawValue)")
    if let frame = report.tableFrame {
      print("消息表格：x=\(Int(frame.x)) y=\(Int(frame.y)) w=\(Int(frame.width)) h=\(Int(frame.height))")
    }
    print("可见消息行：\(report.rows.count)")
    for (rowIndex, row) in report.rows.enumerated() {
      print("row[\(rowIndex)] labels=\(row.labels.count)")
      for label in row.labels {
        if showText {
          print("  \(label)")
        } else {
          print("  <redacted length=\(label.count) hash=\(StableHash.hex(label))>")
        }
      }
    }
    if !showText {
      print("文本默认隐藏；只在你确认终端输出安全时使用 --show-text。")
    }
  }

  private func notificationListen(arguments: [String]) async throws {
    var groups: [String] = []
    var includeExisting = false
    var index = 0

    while index < arguments.count {
      switch arguments[index] {
      case "--group":
        index += 1
        let group = try value(at: index, in: arguments, option: "--group")
        if !groups.contains(group) { groups.append(group) }
      case "--include-existing":
        includeExisting = true
      default:
        throw CLIError.usage("listen 不支持参数：\(arguments[index])")
      }
      index += 1
    }
    guard !groups.isEmpty else {
      throw CLIError.usage("listen 至少需要一个 --group \"群名\"")
    }

    switch notificationReader.availability() {
    case .permissionDenied:
      throw CLIError.usage(
        "无法读取通知数据库：当前终端缺少“完全磁盘访问”权限。"
          + "请运行 wxfomo doctor --open-settings 授权后完全重启终端再试。"
      )
    case .missingFile:
      throw CLIError.usage(
        "通知数据库文件不存在：\(notificationReader.databaseURL.path)。请确认系统通知中心可用。"
      )
    case .readable, .unreadable:
      break
    }

    let encoder = eventEncoder()
    let monitor = WeChatNotificationMonitor(
      groups: groups,
      includeExisting: includeExisting,
      onEvent: makeEventSink(encoder: encoder),
      onLog: { writeStandardError("[wxfomo] \($0)\n") }
    )
    try await monitor.run()
  }

  private func ocrListen(arguments: [String]) async throws {
    var groups: [String] = []
    var interval: TimeInterval = 0.75
    var includeExisting = false
    var index = 0

    while index < arguments.count {
      switch arguments[index] {
      case "--group":
        index += 1
        let group = try value(at: index, in: arguments, option: "--group")
        if !groups.contains(group) { groups.append(group) }
      case "--interval":
        index += 1
        let raw = try value(at: index, in: arguments, option: "--interval")
        guard let parsed = TimeInterval(raw), parsed >= 0.5 else {
          throw CLIError.usage("--interval 必须是不小于 0.5 的秒数")
        }
        interval = parsed
      case "--include-existing":
        includeExisting = true
      default:
        throw CLIError.usage("ocr-listen 不支持参数：\(arguments[index])")
      }
      index += 1
    }

    guard !groups.isEmpty else {
      throw CLIError.usage("ocr-listen 至少需要一个 --group \"群名\"")
    }
    let encoder = eventEncoder()
    let monitor = WeChatOCRMonitor(
      options: MonitorOptions(
        groups: groups,
        interval: interval,
        includeExisting: includeExisting,
        allowSingleGroupFallback: false
      ),
      onEvent: makeEventSink(encoder: encoder),
      onLog: { message in
        writeStandardError("[wxfomo] \(message)\n")
      }
    )
    try await monitor.run()
  }

  private func eventEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private func makeEventSink(encoder: JSONEncoder) -> (MessageEvent) -> Void {
    { event in
      guard let data = try? encoder.encode(event) else { return }
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data([0x0a]))
    }
  }

  private func value(at index: Int, in arguments: [String], option: String) throws -> String {
    guard arguments.indices.contains(index) else {
      throw CLIError.usage("\(option) 缺少值")
    }
    return arguments[index]
  }

  private func printUsage() {
    print(
      """
      wxFomo - macOS 微信群只读消息监听器

      用法：
        wxfomo doctor [--prompt] [--open-settings] [--deep]
        wxfomo probe [--nodes 300]
        wxfomo ocr-probe [--lines 100]
        wxfomo ocr-inspect --group "群名" [--rows 12] [--show-text]
        wxfomo notification-probe [--limit 10] [--show-text]
        wxfomo notification-dump [--limit 10] [--show-text] [--watch [--duration 60]]
        wxfomo inspect --group "群名" [--rows 8] [--show-text]
        wxfomo listen --group "群名" [--group "另一个群"]
        wxfomo ocr-listen --group "群名" [--interval 0.75]

      listen 选项：
        --include-existing   启动时输出当前可见消息；默认只建立基线

      doctor 选项：
        --prompt             触发辅助功能权限申请
        --open-settings      打开“完全磁盘访问”设置面板
        --deep               追加检查系统日志中的微信通知投递活动

      notification-dump 输出通知数据库各表结构、各表行数与各 app 通知数量、
      微信记录解码统计和最近样本；默认脱敏，--show-text 显示原文。
      --watch 进入实时观察：每秒扫描各表新增行，用于确认微信通知行落在哪张表。

      listen 监听 macOS Notification Center 的微信新增通知，不使用 OCR。
      ocr-listen 是窗口 OCR 补漏模式，不会点击、输入或发送微信消息。
      """
    )
  }
}

private func writeStandardError(_ value: String) {
  FileHandle.standardError.write(Data(value.utf8))
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

do {
  try await CLI().run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
  writeStandardError("错误：\(error.localizedDescription)\n")
  exit(1)
}
