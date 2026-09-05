#!/usr/bin/env swift

import Foundation
import Darwin
import Dispatch

private enum ProbeError: Error, CustomStringConvertible {
  case usage(String)
  case sqlite(String)
  case noNotification
  case invalidPayload
  case timedOut(TimeInterval)

  var description: String {
    switch self {
    case .usage(let message): return message
    case .sqlite(let message): return "SQLite 查询失败：\(message)"
    case .noNotification: return "没有找到企业微信通知记录"
    case .invalidPayload: return "通知 payload 不是可识别的 plist"
    case .timedOut(let seconds): return "等待企业微信新通知超时（\(seconds) 秒）"
    }
  }
}

private struct Options {
  var databasePath: String?
  var includeExisting = false
  var once = false
  var nonInteractive = false
  var interactive = false
  var timeout: TimeInterval = 120
  var pollInterval: TimeInterval = 0.5
}

private struct StoredNotification {
  let recordID: Int64
  let sourceIdentifier: String
  let payload: Data
}

private struct NotificationBaseline {
  let latestRecordID: Int64
  let fingerprints: Set<String>
}

private let terminalStateLock = NSLock()
private var terminalSettingsToRestore: termios?
private var terminationSignalSources: [DispatchSourceSignal] = []

private func restoreTerminalSettings() {
  terminalStateLock.lock()
  defer { terminalStateLock.unlock() }
  if var restored = terminalSettingsToRestore {
    tcsetattr(STDIN_FILENO, TCSANOW, &restored)
    terminalSettingsToRestore = nil
  }
}

private func installTerminationSignalHandlers() {
  guard terminationSignalSources.isEmpty else { return }
  let queue = DispatchQueue(label: "wxfomo.wecom-probe.signal-cleanup")
  for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
    Darwin.signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
    source.setEventHandler {
      restoreTerminalSettings()
      Darwin.signal(signalNumber, SIG_DFL)
      raise(signalNumber)
      _exit(128 + signalNumber)
    }
    source.resume()
    terminationSignalSources.append(source)
  }
}

private func parseOptions(_ arguments: [String]) throws -> Options {
  var options = Options()
  var index = 0
  while index < arguments.count {
    switch arguments[index] {
    case "--database":
      index += 1
      guard index < arguments.count else {
        throw ProbeError.usage("--database 需要路径")
      }
      options.databasePath = arguments[index]
    case "--include-existing":
      options.includeExisting = true
    case "--once":
      options.once = true
    case "--non-interactive":
      options.nonInteractive = true
    case "--interactive":
      options.interactive = true
    case "--timeout":
      index += 1
      guard index < arguments.count,
        let value = Double(arguments[index]), value > 0
      else {
        throw ProbeError.usage("--timeout 需要大于 0 的秒数")
      }
      options.timeout = value
    case "--poll-interval":
      index += 1
      guard index < arguments.count,
        let value = Double(arguments[index]), value > 0
      else {
        throw ProbeError.usage("--poll-interval 需要大于 0 的秒数")
      }
      options.pollInterval = value
    case "--help", "-h":
      throw ProbeError.usage(
        "用法：swift scripts/wecom-notification-probe.swift --database PATH --include-existing --once --non-interactive"
      )
    default:
      throw ProbeError.usage("未知参数：\(arguments[index])")
    }
    index += 1
  }
  return options
}

private func sqlite(databasePath: String, query: String) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
  process.arguments = [
    "-readonly", "-cmd", ".timeout 250", "-noheader", "-separator", "\t",
    databasePath, query,
  ]

  let stdout = Pipe()
  let stderr = Pipe()
  process.standardOutput = stdout
  process.standardError = stderr
  try process.run()

  let drains = DispatchGroup()
  var outputData = Data()
  var errorData = Data()
  drains.enter()
  DispatchQueue.global(qos: .userInitiated).async {
    outputData = stdout.fileHandleForReading.readDataToEndOfFile()
    drains.leave()
  }
  drains.enter()
  DispatchQueue.global(qos: .userInitiated).async {
    errorData = stderr.fileHandleForReading.readDataToEndOfFile()
    drains.leave()
  }
  process.waitUntilExit()
  drains.wait()

  guard process.terminationStatus == 0 else {
    let message = String(data: errorData, encoding: .utf8) ?? "exit \(process.terminationStatus)"
    throw ProbeError.sqlite(message.trimmingCharacters(in: .whitespacesAndNewlines))
  }
  return String(data: outputData, encoding: .utf8) ?? ""
}

private func isTransientSQLiteLock(_ message: String) -> Bool {
  let normalized = message.lowercased()
  return normalized.contains("locked") || normalized.contains("busy")
}

private func darwinUserDirectory(environment: [String: String]) -> String? {
  if let overridden = environment["DARWIN_USER_DIR"], !overridden.isEmpty {
    return overridden
  }

  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/getconf")
  process.arguments = ["DARWIN_USER_DIR"]
  let stdout = Pipe()
  process.standardOutput = stdout
  process.standardError = Pipe()
  do {
    try process.run()
    process.waitUntilExit()
  } catch {
    return nil
  }
  guard process.terminationStatus == 0 else { return nil }
  let data = stdout.fileHandleForReading.readDataToEndOfFile()
  let value = String(data: data, encoding: .utf8)?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  return value.isEmpty ? nil : value
}

private enum DatabaseCandidateStatus {
  case usable
  case temporarilyLocked
  case unusable
}

private func notificationDatabaseStatus(_ path: String) -> DatabaseCandidateStatus {
  let schemaProbe = """
    SELECT a.identifier, r.rec_id
    FROM app a
    LEFT JOIN record r ON r.app_id = a.app_id
    LIMIT 0;
    """
  do {
    _ = try sqlite(databasePath: path, query: schemaProbe)
    return .usable
  } catch ProbeError.sqlite(let message) where isTransientSQLiteLock(message) {
    return .temporarilyLocked
  } catch {
    return .unusable
  }
}

private func isCandidateDatabase(_ path: String) -> Bool {
  switch notificationDatabaseStatus(path) {
  case .usable, .temporarilyLocked: return true
  case .unusable: return false
  }
}

private func resolveDatabasePath(explicitPath: String?) throws -> String {
  if let explicitPath = explicitPath {
    return explicitPath
  }

  let environment = ProcessInfo.processInfo.environment
  let home = environment["HOME"] ?? NSHomeDirectory()
  let groupContainerPath = URL(fileURLWithPath: home, isDirectory: true)
    .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
    .path
  if FileManager.default.fileExists(atPath: groupContainerPath),
    isCandidateDatabase(groupContainerPath)
  {
    return groupContainerPath
  }

  if let userDirectory = darwinUserDirectory(environment: environment) {
    let notificationCenterPath = URL(fileURLWithPath: userDirectory, isDirectory: true)
      .appendingPathComponent("com.apple.notificationcenter/db2/db")
      .path
    if FileManager.default.fileExists(atPath: notificationCenterPath),
      isCandidateDatabase(notificationCenterPath)
    {
      return notificationCenterPath
    }
  }
  throw ProbeError.usage("未找到 Notification Center 数据库；可用 --database PATH 指定")
}

private func dataFromHex(_ value: String) -> Data? {
  guard value.count.isMultiple(of: 2) else { return nil }
  var data = Data(capacity: value.count / 2)
  var index = value.startIndex
  while index < value.endIndex {
    let next = value.index(index, offsetBy: 2)
    guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
    data.append(byte)
    index = next
  }
  return data
}

private let notificationFingerprintSQL = """
  CAST(r.rec_id AS TEXT) || ':' ||
  COALESCE(hex(r.uuid), '') || ':' ||
  quote(r.request_date) || ':' ||
  quote(r.request_last_date) || ':' ||
  quote(r.delivered_date)
  """

private func sqlStringLiteral(_ value: String) -> String {
  return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
}

private func storedNotification(
  databasePath: String,
  excluding fingerprints: Set<String> = []
) throws -> StoredNotification {
  let fingerprintFilter: String
  if fingerprints.isEmpty {
    fingerprintFilter = ""
  } else {
    let values = fingerprints.sorted().map(sqlStringLiteral).joined(separator: ",")
    fingerprintFilter = "AND (\(notificationFingerprintSQL)) NOT IN (\(values))"
  }
  let query = """
    SELECT r.rec_id, a.identifier, \(notificationFingerprintSQL), hex(r.data)
    FROM record r
    JOIN app a ON a.app_id = r.app_id
    WHERE lower(trim(a.identifier)) IN (
      'com.tencent.weworkmac',
      '88l2q4487u.com.tencent.weworkmac'
    )
    \(fingerprintFilter)
    ORDER BY COALESCE(r.delivered_date, r.request_last_date, r.request_date, 0) DESC,
      r.rec_id DESC
    LIMIT 1;
    """
  let output = try sqlite(databasePath: databasePath, query: query)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard !output.isEmpty else { throw ProbeError.noNotification }

  let columns = output.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
  guard columns.count == 4,
    let recordID = Int64(columns[0]),
    let payload = dataFromHex(String(columns[3]))
  else {
    throw ProbeError.invalidPayload
  }
  return StoredNotification(
    recordID: recordID,
    sourceIdentifier: String(columns[1]),
    payload: payload
  )
}

private func notificationBaseline(databasePath: String) throws -> NotificationBaseline {
  let query = """
    SELECT r.rec_id, \(notificationFingerprintSQL)
    FROM record r
    JOIN app a ON a.app_id = r.app_id
    WHERE lower(trim(a.identifier)) IN (
      'com.tencent.weworkmac',
      '88l2q4487u.com.tencent.weworkmac'
    )
    ORDER BY r.rec_id;
    """
  let output = try sqlite(databasePath: databasePath, query: query)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard !output.isEmpty else {
    return NotificationBaseline(latestRecordID: 0, fingerprints: [])
  }

  var latestRecordID: Int64 = 0
  var fingerprints = Set<String>()
  for row in output.split(separator: "\n", omittingEmptySubsequences: true) {
    let columns = row.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
    guard columns.count == 2, let recordID = Int64(columns[0]) else {
      throw ProbeError.invalidPayload
    }
    latestRecordID = max(latestRecordID, recordID)
    fingerprints.insert(String(columns[1]))
  }
  return NotificationBaseline(
    latestRecordID: latestRecordID,
    fingerprints: fingerprints
  )
}

private func waitForNotification(
  databasePath: String,
  baseline: NotificationBaseline,
  timeout: TimeInterval,
  pollInterval: TimeInterval
) throws -> StoredNotification {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    do {
      return try storedNotification(
        databasePath: databasePath,
        excluding: baseline.fingerprints
      )
    } catch ProbeError.noNotification {
      Thread.sleep(forTimeInterval: pollInterval)
    } catch ProbeError.sqlite(let message) where isTransientSQLiteLock(message) {
      Thread.sleep(forTimeInterval: pollInterval)
    }
  }
  throw ProbeError.timedOut(timeout)
}

private func retryWhileDatabaseIsLocked<T>(
  timeout: TimeInterval,
  pollInterval: TimeInterval,
  operation: () throws -> T
) throws -> T {
  let deadline = Date().addingTimeInterval(timeout)
  while true {
    do {
      return try operation()
    } catch ProbeError.sqlite(let message) where isTransientSQLiteLock(message) {
      guard Date() < deadline else { throw ProbeError.timedOut(timeout) }
      Thread.sleep(forTimeInterval: pollInterval)
    }
  }
}

private func valueType(_ value: Any?) -> String {
  switch value {
  case is String: return "string"
  case is [Any]: return "array"
  case is [String: Any]: return "object"
  case is Data: return "data"
  case is NSNumber: return "number"
  case nil: return "missing"
  default: return "unknown"
  }
}

private func flattenedStrings(_ value: Any) -> [String] {
  if let string = value as? String { return [string] }
  if let values = value as? [Any] { return values.flatMap(flattenedStrings) }
  if let dictionary = value as? [String: Any] {
    return dictionary.keys.sorted().flatMap { key in
      dictionary[key].map(flattenedStrings) ?? []
    }
  }
  return []
}

private func textLength(_ value: Any?) -> Int {
  guard let value = value else { return 0 }
  return flattenedStrings(value).last?.count ?? 0
}

private func extractedText(_ value: Any?) -> String {
  guard let value = value else { return "" }
  return flattenedStrings(value).last ?? ""
}

private func fieldMatching(_ expected: String, request: [String: Any]) -> String {
  let fields = [("title", "titl"), ("subtitle", "subt"), ("body", "body")]
  return fields.first { _, key in
    extractedText(request[key]) == expected
  }?.0 ?? "unmatched"
}

private func readExpectation(prompt: String) throws -> String {
  print(prompt, terminator: "")
  fflush(stdout)

  var echoWasDisabled = false
  if isatty(STDIN_FILENO) == 1 {
    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else {
      throw ProbeError.usage("无法读取终端设置，已拒绝接收明文输入")
    }
    var protected = original
    protected.c_lflag &= ~tcflag_t(ECHO)
    terminalStateLock.lock()
    let result = tcsetattr(STDIN_FILENO, TCSANOW, &protected)
    if result == 0 {
      terminalSettingsToRestore = original
      echoWasDisabled = true
    }
    terminalStateLock.unlock()
    guard result == 0 else {
      throw ProbeError.usage("无法关闭终端回显，已拒绝接收明文输入")
    }
  }
  defer {
    if echoWasDisabled {
      restoreTerminalSettings()
      print("")
    }
  }

  guard let value = readLine() else { throw ProbeError.usage("交互输入提前结束") }
  return value
}

private struct AttachmentSummary {
  let identity: String
  let kind: String
}

private func attachmentKind(locator: String, typeHint: String) -> String {
  let normalizedHint = typeHint.lowercased()
  if normalizedHint.contains("image") || normalizedHint.contains("png") || normalizedHint.contains("jpeg") {
    return "image"
  }
  if normalizedHint.contains("video") || normalizedHint.contains("movie") { return "video" }
  if normalizedHint.contains("audio") { return "audio" }

  let pathExtension = URL(string: locator)?.pathExtension.lowercased()
    ?? URL(fileURLWithPath: locator).pathExtension.lowercased()
  switch pathExtension {
  case "png", "jpg", "jpeg", "gif", "heic", "webp": return "image"
  case "mov", "mp4", "m4v", "avi", "webm": return "video"
  case "mp3", "m4a", "aac", "wav", "caf", "flac", "ogg": return "audio"
  default: return "file"
  }
}

private func collectAttachmentSummaries(_ value: Any) -> [AttachmentSummary] {
  if let values = value as? [Any] {
    return values.flatMap(collectAttachmentSummaries)
  }
  guard let dictionary = value as? [String: Any] else { return [] }

  var normalized: [String: Any] = [:]
  for (key, child) in dictionary {
    let normalizedKey = key.lowercased()
    if normalized[normalizedKey] == nil {
      normalized[normalizedKey] = child
    }
  }
  let typeHint = (normalized["type"] as? String)
    ?? (normalized["uti"] as? String)
    ?? (normalized["typehint"] as? String)
    ?? ""
  let locatorKeys = ["url", "fileurl", "path", "filepath", "localurl"]
  var results: [AttachmentSummary] = []
  for key in locatorKeys {
    guard let locator = normalized[key] as? String, !locator.isEmpty else { continue }
    results.append(
      AttachmentSummary(
        identity: locator,
        kind: attachmentKind(locator: locator, typeHint: typeHint)
      )
    )
  }
  for (key, child) in normalized where !locatorKeys.contains(key) {
    results.append(contentsOf: collectAttachmentSummaries(child))
  }
  return results
}

private func attachmentSummaries(request: [String: Any]) -> [AttachmentSummary] {
  let containers = request.compactMap { key, value -> Any? in
    let normalized = key.lowercased()
    return normalized == "atta" || normalized.contains("attach") ? value : nil
  }
  var seen = Set<String>()
  return containers
    .flatMap(collectAttachmentSummaries)
    .filter { seen.insert($0.identity).inserted }
}

private func report(_ notification: StoredNotification, interactive: Bool) throws {
  guard
    let root = try PropertyListSerialization.propertyList(
      from: notification.payload,
      options: [],
      format: nil
    ) as? [String: Any],
    let request = root["req"] as? [String: Any]
  else {
    throw ProbeError.invalidPayload
  }

  print("source.identifier=\(notification.sourceIdentifier)")
  print("record.id=\(notification.recordID)")
  print("payload.top_level_keys=\(root.keys.sorted().joined(separator: ","))")
  print("payload.request_keys=\(request.keys.sorted().joined(separator: ","))")

  for (label, key) in [("title", "titl"), ("subtitle", "subt"), ("body", "body")] {
    let value = request[key]
    print("payload.\(label).type=\(valueType(value)) length=\(textLength(value))")
  }
  let attachments = attachmentSummaries(request: request)
  print("payload.attachments.count=\(attachments.count)")
  let attachmentKinds = Set(attachments.map { $0.kind }).sorted()
  print("payload.attachments.kinds=\(attachmentKinds.joined(separator: ","))")

  if interactive {
    let expectedGroup = try readExpectation(prompt: "请输入测试群名（不会保存或输出）：")
    let expectedSender = try readExpectation(prompt: "请输入测试发送者（不会保存或输出）：")
    let expectedBody = try readExpectation(prompt: "请输入测试正文（不会保存或输出）：")
    print("match.group=\(fieldMatching(expectedGroup, request: request))")
    print("match.sender=\(fieldMatching(expectedSender, request: request))")
    print("match.body=\(fieldMatching(expectedBody, request: request))")
  }
}

do {
  let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
  guard options.once, options.nonInteractive != options.interactive
  else {
    throw ProbeError.usage("当前版本需要 --once，并选择 --interactive 或 --non-interactive")
  }
  if options.interactive {
    installTerminationSignalHandlers()
  }
  let databasePath = try resolveDatabasePath(explicitPath: options.databasePath)
  print("database.path=\(databasePath)")
  let notification: StoredNotification
  if options.includeExisting {
    notification = try retryWhileDatabaseIsLocked(
      timeout: options.timeout,
      pollInterval: options.pollInterval
    ) {
      try storedNotification(databasePath: databasePath)
    }
  } else {
    let baseline = try retryWhileDatabaseIsLocked(
      timeout: options.timeout,
      pollInterval: options.pollInterval
    ) {
      try notificationBaseline(databasePath: databasePath)
    }
    print("monitor.baseline_record_id=\(baseline.latestRecordID)")
    fflush(stdout)
    notification = try waitForNotification(
      databasePath: databasePath,
      baseline: baseline,
      timeout: options.timeout,
      pollInterval: options.pollInterval
    )
  }
  try report(
    notification,
    interactive: options.interactive
  )
} catch {
  fputs("ERROR: \(error)\n", stderr)
  exit(1)
}
