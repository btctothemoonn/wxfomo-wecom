#!/usr/bin/env swift

import Darwin
import Foundation
import SQLite3

private enum ListenerError: Error, CustomStringConvertible {
  case usage(String)
  case databaseMissing(String)
  case database(String)
  case notificationSourceChanged(String)
  case storage(String)
  case sqliteStorage(Int32, String)
  case noGroups(String)
  case invalidPayload
  case timedOut(TimeInterval)

  var description: String {
    switch self {
    case .usage(let message), .databaseMissing(let message): return message
    case .database(let message): return "通知数据库读取失败：\(message)"
    case .notificationSourceChanged(let message): return "通知数据库读取失败：\(message)"
    case .storage(let message): return "消息持久化失败：\(message)"
    case .sqliteStorage(_, let message): return "消息持久化失败：\(message)"
    case .noGroups(let path):
      return "没有配置监听群。请使用 --group \"完整群名\" --save-groups；配置文件：\(path)"
    case .invalidPayload: return "通知内容不是可识别的 plist"
    case .timedOut(let seconds): return "等待指定企业微信群消息超时（\(seconds) 秒）"
    }
  }
}

private struct Options {
  var databasePath: String?
  var instanceID: String?
  var configPath: String
  var storePath: String
  var commandLineGroups: [String] = []
  var savesGroups = false
  var includesExisting = false
  var once = false
  var timeout: TimeInterval = 120
  var pollInterval: TimeInterval = 0.1

  init() {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    configPath = URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent(".config/wxfomo/wecom-groups.txt")
      .path
    storePath = ProcessInfo.processInfo.environment["WXFOMO_LAN_DATABASE"].flatMap {
      $0.isEmpty ? nil : $0
    } ?? URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent("Library/Application Support/wxFomo LAN/messages.sqlite3")
      .path
  }
}

private var didStopAfterSourceValidationForTest = false
private var didStopAfterStartupBindingForTest = false
private var didStopBeforeSourceValidationConfirmationForTest = false

private enum ListenerTestFlags {
  static let stopAfterSourceValidation = getenv("WXFOMO_TEST_STOP_AFTER_SOURCE_VALIDATION")
    .map { strcmp($0, "1") == 0 } ?? false
  static let stopAfterStartupBinding = getenv("WXFOMO_TEST_STOP_AFTER_STARTUP_BINDING")
    .map { strcmp($0, "1") == 0 } ?? false
  static let stopBeforeSourceValidationConfirmation = getenv(
    "WXFOMO_TEST_STOP_BEFORE_SOURCE_VALIDATION_CONFIRMATION"
  ).map { strcmp($0, "1") == 0 } ?? false
}

private func stopAfterSourceValidationForTestIfRequested() {
  guard !didStopAfterSourceValidationForTest,
    ListenerTestFlags.stopAfterSourceValidation
  else {
    return
  }
  didStopAfterSourceValidationForTest = true
  raise(SIGSTOP)
}

private func stopAfterStartupBindingForTestIfRequested() {
  guard !didStopAfterStartupBindingForTest,
    ListenerTestFlags.stopAfterStartupBinding
  else {
    return
  }
  didStopAfterStartupBindingForTest = true
  raise(SIGSTOP)
}

private func stopBeforeSourceValidationConfirmationForTestIfRequested() {
  guard !didStopBeforeSourceValidationConfirmationForTest,
    ListenerTestFlags.stopBeforeSourceValidationConfirmation
  else {
    return
  }
  didStopBeforeSourceValidationConfirmationForTest = true
  raise(SIGSTOP)
}

private func delayLegacyAliasScanRowForTestIfRequested() {
  guard let rawValue = ProcessInfo.processInfo.environment[
      "WXFOMO_TEST_LEGACY_ALIAS_SCAN_ROW_DELAY"
    ],
    let requestedDelay = TimeInterval(rawValue),
    requestedDelay > 0
  else {
    return
  }
  Thread.sleep(forTimeInterval: min(requestedDelay, 0.1))
}

private final class SQLiteDeadlineContext {
  let deadline: Date

  init(deadline: Date) {
    self.deadline = deadline
  }
}

private let sqliteDeadlineProgressCallback: @convention(c) (
  UnsafeMutableRawPointer?
) -> Int32 = { rawContext in
  guard let rawContext = rawContext else { return 0 }
  let context = Unmanaged<SQLiteDeadlineContext>
    .fromOpaque(rawContext)
    .takeUnretainedValue()
  return Date() >= context.deadline ? 1 : 0
}

private struct StoredNotification {
  let recordID: Int64
  let eventID: String
  let stableUUID: String?
  let uuidStorageBytesHex: String
  let hasStableUUID: Bool
  let legacyLANEventID: String
  let legacyNativeEventID: String?
  let updateTimestamp: Double
  let deliveredAt: Date
  let payload: Data
}

private enum NotificationFetch {
  case latest(Int)
  case since(Double, Int64, Int)
  case recordIDs([Int64])
}

private struct NotificationCursor {
  var timestamp: Double
  var recordID: Int64

  init(baseline: [StoredNotification]) {
    let latest = baseline.max {
      ($0.updateTimestamp, $0.recordID) < ($1.updateTimestamp, $1.recordID)
    }
    timestamp = latest?.updateTimestamp ?? 0
    recordID = latest?.recordID ?? Int64.min
  }

  init(timestamp: Double, recordID: Int64) {
    self.timestamp = timestamp
    self.recordID = recordID
  }

  func accepts(_ notification: StoredNotification) -> Bool {
    return (notification.updateTimestamp, notification.recordID) > (timestamp, recordID)
  }

  mutating func advance(to notification: StoredNotification) {
    timestamp = notification.updateTimestamp
    recordID = notification.recordID
  }
}

private func ambiguousLegacyAliasOwnerIDs(
  _ entries: [(ownerID: Int64, aliases: [String])]
) -> Set<Int64> {
  let ownersByAlias = legacyAliasOwners(entries)
  var ambiguousOwners = Set<Int64>()
  for owners in ownersByAlias.values where owners.count > 1 {
    ambiguousOwners.formUnion(owners)
  }
  return ambiguousOwners
}

private func legacyAliasOwners(
  _ entries: [(ownerID: Int64, aliases: [String])]
) -> [String: Set<Int64>] {
  var ownersByAlias: [String: Set<Int64>] = [:]
  for entry in entries {
    for alias in entry.aliases {
      ownersByAlias[alias, default: []].insert(entry.ownerID)
    }
  }
  return ownersByAlias
}

private func runPrefixAliasPreflightSelfTestIfRequested() {
  guard ProcessInfo.processInfo.environment[
    "WXFOMO_TEST_PREFIX_ALIAS_PREFLIGHT"
  ] == "1" else {
    return
  }
  let ambiguous = ambiguousLegacyAliasOwnerIDs([
    (ownerID: 1, aliases: ["only-a", "shared", "shared"]),
    (ownerID: 2, aliases: ["only-b", "shared"]),
    (ownerID: 3, aliases: ["only-c"]),
  ])
  guard ambiguous == Set([Int64(1), Int64(2)]),
    ambiguousLegacyAliasOwnerIDs([
      (ownerID: 1, aliases: ["a"]),
      (ownerID: 2, aliases: ["b"]),
    ]).isEmpty
  else {
    fputs("FAIL: 旧原生前缀 alias 全局预检\n", stderr)
    exit(2)
  }
  print("PASS: 旧原生前缀 alias 全局预检")
  exit(0)
}

private struct GroupMessage {
  let group: String
  let sender: String
  let content: String
}

private func trimmed(_ value: String) -> String {
  return value.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func canonicalGroupName(_ value: String) -> String {
  return trimmed(value).precomposedStringWithCanonicalMapping
}

private func uniqueNonempty(_ values: [String]) -> [String] {
  var seen = Set<String>()
  return values.map(trimmed).filter {
    let key = canonicalGroupName($0)
    return !key.isEmpty && seen.insert(key).inserted
  }
}

private func parseOptions(_ arguments: [String]) throws -> Options {
  var options = Options()
  var index = 0
  while index < arguments.count {
    switch arguments[index] {
    case "--database":
      index += 1
      guard index < arguments.count else { throw ListenerError.usage("--database 需要路径") }
      options.databasePath = arguments[index]
    case "--config":
      index += 1
      guard index < arguments.count else { throw ListenerError.usage("--config 需要路径") }
      options.configPath = arguments[index]
    case "--store":
      index += 1
      guard index < arguments.count else { throw ListenerError.usage("--store 需要路径") }
      options.storePath = arguments[index]
    case "--instance-id":
      index += 1
      guard index < arguments.count, UUID(uuidString: arguments[index]) != nil else {
        throw ListenerError.usage("--instance-id 需要 UUID")
      }
      options.instanceID = arguments[index].lowercased()
    case "--group":
      index += 1
      guard index < arguments.count else { throw ListenerError.usage("--group 需要完整群名") }
      options.commandLineGroups.append(arguments[index])
    case "--save-groups":
      options.savesGroups = true
    case "--include-existing":
      options.includesExisting = true
    case "--once":
      options.once = true
    case "--timeout":
      index += 1
      guard index < arguments.count,
        let value = Double(arguments[index]), value > 0
      else {
        throw ListenerError.usage("--timeout 需要大于 0 的秒数")
      }
      options.timeout = value
    case "--poll-interval":
      index += 1
      guard index < arguments.count,
        let value = Double(arguments[index]), value >= 0.05
      else {
        throw ListenerError.usage("--poll-interval 需要不小于 0.05 秒")
      }
      options.pollInterval = value
    case "--help", "-h":
      throw ListenerError.usage(
        """
        用法：
          swift scripts/wecom-group-listener.swift --group "完整群名" --save-groups
          swift scripts/wecom-group-listener.swift

        选项：
          --group NAME          本次监听的完整群名，可重复
          --save-groups         将 --group 保存到本机私有配置
          --config PATH         指定群名配置文件
          --database PATH       指定 Notification Center 数据库
          --store PATH          指定私有消息 SQLite 数据库
          --include-existing    启动时输出最近最多 500 条通知；默认仅监听新通知
          --once               收到一条匹配消息后退出
          --timeout SECONDS     --once 的等待时间，默认 120 秒
          --poll-interval SEC   扫描间隔，默认 0.1 秒
        """
      )
    default:
      throw ListenerError.usage("未知参数：\(arguments[index])")
    }
    index += 1
  }
  options.commandLineGroups = uniqueNonempty(options.commandLineGroups)
  if options.savesGroups && options.commandLineGroups.isEmpty {
    throw ListenerError.usage("--save-groups 必须同时提供至少一个 --group")
  }
  return options
}

private enum SafePathError: Error, CustomStringConvertible {
  case invalid(String)

  var description: String {
    switch self {
    case .invalid(let message): return message
    }
  }
}

private struct SafeParent {
  let descriptor: Int32
  let path: String
  let name: String
}

private func pathError(_ message: String) -> SafePathError {
  return .invalid(message)
}

private func fileType(_ info: stat) -> mode_t {
  return info.st_mode & mode_t(S_IFMT)
}

private func fileMode(_ info: stat) -> mode_t {
  return info.st_mode & mode_t(0o777)
}

private func validatePrivateDirectory(_ info: stat) throws {
  guard fileType(info) == mode_t(S_IFDIR), info.st_uid == geteuid(), fileMode(info) == 0o700 else {
    throw pathError("直接父目录必须是当前用户所有的 0700 真实目录")
  }
}

private func validateCreationParent(_ info: stat) throws {
  guard fileType(info) == mode_t(S_IFDIR), info.st_uid == geteuid(), fileMode(info) & 0o022 == 0 else {
    throw pathError("不能在不安全的上级目录中创建私有目录")
  }
}

private func safeParent(for path: String, createIfMissing: Bool) throws -> SafeParent {
  let fileURL = URL(fileURLWithPath: path).standardizedFileURL
  let directoryURL = fileURL.deletingLastPathComponent()
  let name = fileURL.lastPathComponent
  guard !name.isEmpty, name != ".", name != ".." else {
    throw pathError("文件路径无效")
  }

  var before = stat()
  if lstat(directoryURL.path, &before) != 0 {
    guard errno == ENOENT, createIfMissing else {
      throw pathError("无法验证直接父目录")
    }
    let creationParentURL = directoryURL.deletingLastPathComponent()
    let newDirectoryName = directoryURL.lastPathComponent
    guard !newDirectoryName.isEmpty else { throw pathError("文件路径无效") }
    var creationParentInfo = stat()
    guard lstat(creationParentURL.path, &creationParentInfo) == 0 else {
      throw pathError("不会递归创建缺失的上级目录")
    }
    try validateCreationParent(creationParentInfo)
    let creationParentFD = open(
      creationParentURL.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard creationParentFD >= 0 else { throw pathError("无法安全打开上级目录") }
    defer { close(creationParentFD) }
    var creationParentAfter = stat()
    guard fstat(creationParentFD, &creationParentAfter) == 0,
      creationParentInfo.st_dev == creationParentAfter.st_dev,
      creationParentInfo.st_ino == creationParentAfter.st_ino
    else {
      throw pathError("上级目录在验证期间已更改")
    }
    try validateCreationParent(creationParentAfter)
    let created = newDirectoryName.withCString {
      mkdirat(creationParentFD, $0, mode_t(0o700))
    }
    guard created == 0 else { throw pathError("无法创建私有直接父目录") }
    guard lstat(directoryURL.path, &before) == 0 else {
      throw pathError("无法验证新建直接父目录")
    }
  }
  try validatePrivateDirectory(before)
  let directoryFD = open(
    directoryURL.path,
    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
  )
  guard directoryFD >= 0 else { throw pathError("无法安全打开直接父目录") }
  var after = stat()
  guard fstat(directoryFD, &after) == 0,
    before.st_dev == after.st_dev,
    before.st_ino == after.st_ino
  else {
    close(directoryFD)
    throw pathError("直接父目录在验证期间已更改")
  }
  do {
    try validatePrivateDirectory(after)
  } catch {
    close(directoryFD)
    throw error
  }
  return SafeParent(descriptor: directoryFD, path: directoryURL.path, name: name)
}

private func safeRegularDescriptor(
  parent: SafeParent,
  flags: Int32,
  missingIsAllowed: Bool
) throws -> Int32? {
  var before = stat()
  let status = parent.name.withCString {
    fstatat(parent.descriptor, $0, &before, AT_SYMLINK_NOFOLLOW)
  }
  if status != 0 {
    if errno == ENOENT, missingIsAllowed { return nil }
    throw pathError("无法验证目标文件")
  }
  guard fileType(before) == mode_t(S_IFREG), before.st_uid == geteuid(), before.st_nlink == 1,
    fileMode(before) & 0o077 == 0
  else {
    throw pathError("目标必须是当前用户所有的单链接私有普通文件")
  }
  let descriptor = parent.name.withCString {
    openat(parent.descriptor, $0, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0))
  }
  guard descriptor >= 0 else { throw pathError("无法安全打开目标文件") }
  var after = stat()
  guard fstat(descriptor, &after) == 0,
    before.st_dev == after.st_dev,
    before.st_ino == after.st_ino,
    fileType(after) == mode_t(S_IFREG),
    after.st_uid == geteuid(),
    after.st_nlink == 1,
    fileMode(after) & 0o077 == 0
  else {
    close(descriptor)
    throw pathError("目标文件在验证期间已更改")
  }
  return descriptor
}

private func loadGroups(from path: String) throws -> [String] {
  var pathInfo = stat()
  if lstat(path, &pathInfo) != 0 {
    if errno == ENOENT { return [] }
    throw ListenerError.usage("无法验证群名配置文件")
  }
  let parent: SafeParent
  do {
    parent = try safeParent(for: path, createIfMissing: false)
  } catch {
    throw ListenerError.usage("群名配置路径不安全：\(error)")
  }
  defer { close(parent.descriptor) }
  let descriptor: Int32
  do {
    guard let opened = try safeRegularDescriptor(
      parent: parent,
      flags: O_RDONLY,
      missingIsAllowed: false
    ) else {
      return []
    }
    descriptor = opened
  } catch {
    throw ListenerError.usage("群名配置文件不安全：\(error)")
  }
  let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  let data = handle.readDataToEndOfFile()
  guard let value = String(data: data, encoding: .utf8) else {
    throw ListenerError.usage("群名配置文件必须是 UTF-8")
  }
  return uniqueNonempty(
    value.components(separatedBy: .newlines).filter {
      !trimmed($0).hasPrefix("#")
    }
  )
}

private func saveGroups(_ groups: [String], to path: String) throws {
  let parent: SafeParent
  do {
    parent = try safeParent(for: path, createIfMissing: true)
  } catch {
    throw ListenerError.usage("群名配置路径不安全：\(error)")
  }
  defer { close(parent.descriptor) }
  do {
    if let existing = try safeRegularDescriptor(
      parent: parent,
      flags: O_RDONLY,
      missingIsAllowed: true
    ) {
      close(existing)
    }
  } catch {
    throw ListenerError.usage("群名配置文件不安全：\(error)")
  }

  let temporaryName = ".\(parent.name).tmp.\(getpid()).\(UUID().uuidString)"
  let temporaryFD = temporaryName.withCString {
    openat(
      parent.descriptor,
      $0,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      mode_t(0o600)
    )
  }
  guard temporaryFD >= 0 else { throw ListenerError.usage("无法创建私有临时配置文件") }
  var keepsTemporary = true
  defer {
    close(temporaryFD)
    if keepsTemporary {
      temporaryName.withCString { _ = unlinkat(parent.descriptor, $0, 0) }
    }
  }
  guard fchmod(temporaryFD, mode_t(0o600)) == 0 else {
    throw ListenerError.usage("无法设置私有临时配置文件权限")
  }
  let data = Data((groups.joined(separator: "\n") + "\n").utf8)
  let bytes = (data as NSData).bytes
  var offset = 0
  while offset < data.count {
    let count = Darwin.write(temporaryFD, bytes.advanced(by: offset), data.count - offset)
    if count < 0, errno == EINTR { continue }
    guard count > 0 else { throw ListenerError.usage("无法写入私有配置文件") }
    offset += count
  }
  guard fsync(temporaryFD) == 0 else { throw ListenerError.usage("无法同步私有配置文件") }
  let renamed = temporaryName.withCString { temporary in
    parent.name.withCString { destination in
      renameat(parent.descriptor, temporary, parent.descriptor, destination)
    }
  }
  guard renamed == 0 else { throw ListenerError.usage("无法原子更新私有配置文件") }
  keepsTemporary = false
  guard fsync(parent.descriptor) == 0 else {
    throw ListenerError.usage("无法同步私有配置目录")
  }
}

private func sqliteMessage(_ database: OpaquePointer?) -> String {
  guard let database = database, let value = sqlite3_errmsg(database) else { return "未知错误" }
  return String(cString: value)
}

private func sqliteStorageError(_ database: OpaquePointer) -> ListenerError {
  return .sqliteStorage(sqlite3_extended_errcode(database), sqliteMessage(database))
}

private final class MessageDatabase {
  private static let legacyAliasMigrationVersion: Int64 = 2_026_090_301
  private static let legacyPrefixAliasMigrationVersion: Int64 = 2_026_090_302
  private static let oldLegacyAliasProvenanceVersion: Int64 = 2_026_090_303
  private static let legacyPrefixAliasAuditVersion: Int64 = 2_026_090_304
  private static let legacyAliasProvenanceVersion: Int64 = 2_026_090_305
  private static let legacyPartialRecoveryVersion: Int64 = 2_026_090_306
  private let database: OpaquePointer
  private let instanceID: String

  init(path: String, groups: [String], instanceID: String) throws {
    let parent: SafeParent
    do {
      parent = try safeParent(for: path, createIfMissing: true)
    } catch {
      throw ListenerError.storage("消息库路径不安全：\(error)")
    }
    defer { close(parent.descriptor) }
    do {
      if let existing = try safeRegularDescriptor(
        parent: parent,
        flags: O_RDWR,
        missingIsAllowed: true
      ) {
        close(existing)
      } else {
        let created = parent.name.withCString {
          openat(
            parent.descriptor,
            $0,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
            mode_t(0o600)
          )
        }
        guard created >= 0 else { throw pathError("无法安全创建消息库") }
        guard fchmod(created, mode_t(0o600)) == 0 else {
          close(created)
          throw pathError("无法设置新建消息库权限")
        }
        var createdInfo = stat()
        guard fstat(created, &createdInfo) == 0,
          fileType(createdInfo) == mode_t(S_IFREG),
          createdInfo.st_uid == geteuid(),
          createdInfo.st_nlink == 1,
          fileMode(createdInfo) == 0o600
        else {
          close(created)
          throw pathError("新建消息库未通过安全验证")
        }
        close(created)
      }
    } catch {
      throw ListenerError.storage("消息库文件不安全：\(error)")
    }

    guard let resolvedParentPointer = realpath(parent.path, nil) else {
      throw ListenerError.storage("无法解析已验证的消息库目录")
    }
    let resolvedStorePath = URL(
      fileURLWithPath: String(cString: resolvedParentPointer),
      isDirectory: true
    ).appendingPathComponent(parent.name).path
    free(resolvedParentPointer)
    var opened: OpaquePointer?
    let result = sqlite3_open_v2(
      resolvedStorePath,
      &opened,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | Int32(0x01000000),
      nil
    )
    guard result == SQLITE_OK, let openedDatabase = opened else {
      let message = sqliteMessage(opened)
      if let opened = opened { sqlite3_close(opened) }
      throw ListenerError.storage(message)
    }
    database = openedDatabase
    self.instanceID = instanceID

    do {
      guard sqlite3_busy_timeout(database, 1000) == SQLITE_OK else {
        throw ListenerError.storage("无法设置 busy_timeout：\(sqliteMessage(database))")
      }
      try execute("PRAGMA foreign_keys=ON")
      try execute("PRAGMA journal_mode=WAL")
      try execute(
        """
        CREATE TABLE IF NOT EXISTS schema_migrations(
          version INTEGER PRIMARY KEY,
          applied_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS conversations(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          source TEXT NOT NULL DEFAULT 'wecom_notification',
          group_name TEXT NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          last_message_at REAL,
          message_count INTEGER NOT NULL DEFAULT 0,
          UNIQUE(source, group_name)
        );
        CREATE TABLE IF NOT EXISTS messages(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          event_id TEXT NOT NULL UNIQUE,
          conversation_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE RESTRICT,
          group_name TEXT NOT NULL,
          sender_display_name TEXT,
          sender_stable_id TEXT,
          content TEXT NOT NULL,
          message_type TEXT NOT NULL CHECK(message_type IN ('text','media','system','unknown')),
          observed_at REAL NOT NULL,
          source_sequence INTEGER,
          attachments_json BLOB NOT NULL DEFAULT X'5B5D',
          attachment_count INTEGER NOT NULL DEFAULT 0,
          sender_confidence TEXT NOT NULL DEFAULT 'notification_payload',
          is_from_self INTEGER NOT NULL DEFAULT 0 CHECK(is_from_self IN (0,1)),
          inserted_at REAL NOT NULL,
          record_version INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX IF NOT EXISTS messages_lan_timeline_idx
          ON messages(observed_at, event_id, id);
        CREATE TABLE IF NOT EXISTS message_event_aliases(
          alias_event_id TEXT PRIMARY KEY,
          message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
          created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS message_event_aliases_message_idx
          ON message_event_aliases(message_id);
        CREATE TABLE IF NOT EXISTS message_legacy_alias_provenance(
          message_id INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
          version INTEGER NOT NULL,
          completed_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS message_event_alias_quarantine(
          alias_event_id TEXT PRIMARY KEY,
          version INTEGER NOT NULL,
          claimant_message_ids_json TEXT NOT NULL,
          quarantined_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS listener_state(
          singleton_id INTEGER PRIMARY KEY CHECK(singleton_id = 1),
          instance_id TEXT NOT NULL,
          group_names_json TEXT NOT NULL,
          started_at REAL NOT NULL,
          heartbeat_at REAL NOT NULL,
          cursor_timestamp REAL,
          cursor_record_id INTEGER,
          source_key TEXT,
          updated_at REAL NOT NULL,
          CHECK (
            (cursor_timestamp IS NULL AND cursor_record_id IS NULL) OR
            (cursor_timestamp IS NOT NULL AND cursor_record_id IS NOT NULL)
          )
        );
        """
      )
      try ensureListenerStateColumns()
      try beginListenerInstance(groups: groups)
    } catch {
      sqlite3_close(database)
      throw error
    }
  }

  deinit {
    sqlite3_close(database)
  }

  func cursor() throws -> NotificationCursor? {
    let statement = try prepare(
      """
      SELECT cursor_timestamp, cursor_record_id
      FROM listener_state
      WHERE singleton_id = 1 AND instance_id = ?
      """
    )
    defer { sqlite3_finalize(statement) }
    try bindText(instanceID, to: statement, at: 1)
    let step = sqlite3_step(statement)
    guard step == SQLITE_ROW else {
      if step == SQLITE_DONE { throw ListenerError.storage("监听实例已被替换") }
      throw sqliteStorageError(database)
    }
    let timestampIsNull = sqlite3_column_type(statement, 0) == SQLITE_NULL
    let recordIDIsNull = sqlite3_column_type(statement, 1) == SQLITE_NULL
    guard timestampIsNull == recordIDIsNull else {
      throw ListenerError.storage("监听游标状态不完整")
    }
    if timestampIsNull { return nil }
    return NotificationCursor(
      timestamp: sqlite3_column_double(statement, 0),
      recordID: sqlite3_column_int64(statement, 1)
    )
  }

  struct SourceBinding {
    let requiresSafetyReplay: Bool
    let legacyAliasMigrationPending: Bool
    let legacyAliasCandidates: [LegacyAliasCandidate]
    let legacyAliasExpectedMessageIDs: Set<Int64>
  }

  struct LegacyAliasCandidate {
    let messageID: Int64
    let recordID: Int64
    let storedEventID: String
    let legacyEventID: String
    let uuidStorageBytesHex: String
    let group: String
    let sender: String
    let content: String
    let retainedAliases: [String]
    let hasPartialLegacyProvenance: Bool
  }

  struct LegacyAliasConsolidationPlan {
    let notification: StoredNotification
    let message: GroupMessage
    let candidates: [LegacyAliasCandidate]
    let aliases: [String]
    let protectedAliases: Set<String>
    let candidateIDs: Set<Int64>
    let survivorID: Int64
    let recoversLegacyPartialState: Bool
  }

  struct LegacyPrefixAliasCandidate {
    let messageID: Int64
    let recordID: Int64
    let canonicalEventID: String
    let uuidStorageBytesHex: String
    let group: String
    let sender: String
    let content: String
    let standaloneEventIDs: [String]
    let retainedEventIDs: [String]
    let retainedEventCreatedAt: [String: Double]
    let version1AppliedAt: Double?
    let requiresVersion1SemanticWitness: Bool
  }

  struct LegacyPrefixAliasScan {
    let candidates: [LegacyPrefixAliasCandidate]
    let unresolvedMessageIDs: Set<Int64>
    let quarantinedEventIDs: Set<String>
  }

  private struct LegacyPrefixAliasSeed {
    let messageID: Int64
    let canonicalEventID: String
    let sourceSequence: Int64
    let group: String
    let sender: String
    let content: String
    var standaloneEventIDs: [String]
    var retainedEventIDs: [String]
    var retainedEventCreatedAt: [String: Double]
    let hasCompleteRevisionProvenance: Bool
  }

  private struct LegacyAliasScan {
    let candidates: [LegacyAliasCandidate]
    let expectedMessageIDs: Set<Int64>
  }

  private final class LegacyAliasMessageSeed {
    let messageID: Int64
    let storedEventID: String
    let sourceSequence: Int64?
    let group: String
    let sender: String
    let content: String
    var retainedAliases: [String]
    let hasPartialLegacyProvenance: Bool

    init(
      messageID: Int64,
      storedEventID: String,
      sourceSequence: Int64?,
      group: String,
      sender: String,
      content: String,
      retainedAliases: [String],
      hasPartialLegacyProvenance: Bool
    ) {
      self.messageID = messageID
      self.storedEventID = storedEventID
      self.sourceSequence = sourceSequence
      self.group = group
      self.sender = sender
      self.content = content
      self.retainedAliases = retainedAliases
      self.hasPartialLegacyProvenance = hasPartialLegacyProvenance
    }
  }

  func bindSource(
    _ sourceKey: String,
    deadline: Date? = nil,
    timeout: TimeInterval = 0
  ) throws -> SourceBinding {
    do {
      try execute("BEGIN IMMEDIATE")
      try assertOwnership()
      let state = try listenerSourceState()
      let previousSource = state.sourceKey
      let timestampIsNull = state.cursorTimestampIsNull
      let recordIDIsNull = state.cursorRecordIDIsNull
      guard timestampIsNull == recordIDIsNull else {
        throw ListenerError.storage("监听游标状态不完整")
      }
      let requiresSafetyReplay = previousSource == nil
        ? !timestampIsNull
        : previousSource != sourceKey || timestampIsNull
      let legacyAliasScan = try migratePrecanonicalAliasesIfNeeded(
        deadline: deadline,
        timeout: timeout
      )
      try checkDeadline(deadline, timeout: timeout)
      let legacyAliasCandidates = legacyAliasScan.candidates
      let legacyAliasMigrationPending = !legacyAliasScan.expectedMessageIDs.isEmpty
      if previousSource != sourceKey {
        try checkDeadline(deadline, timeout: timeout)
        let update = try prepare(
          """
          UPDATE listener_state
          SET source_key = ?, cursor_timestamp = NULL, cursor_record_id = NULL, updated_at = ?
          WHERE singleton_id = 1 AND instance_id = ?
          """
        )
        defer { sqlite3_finalize(update) }
        try bindText(sourceKey, to: update, at: 1)
        try bindDouble(Date().timeIntervalSince1970, to: update, at: 2)
        try bindText(instanceID, to: update, at: 3)
        guard sqlite3_step(update) == SQLITE_DONE else { throw sqliteStorageError(database) }
        guard sqlite3_changes(database) == 1 else {
          throw ListenerError.storage("监听实例已被替换")
        }
      }
      try checkDeadline(deadline, timeout: timeout)
      try execute("COMMIT")
      return SourceBinding(
        requiresSafetyReplay: requiresSafetyReplay || legacyAliasMigrationPending,
        legacyAliasMigrationPending: legacyAliasMigrationPending,
        legacyAliasCandidates: legacyAliasCandidates,
        legacyAliasExpectedMessageIDs: legacyAliasScan.expectedMessageIDs
      )
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  func persist(notification: StoredNotification, message: GroupMessage?) throws -> Bool {
    do {
      try execute("BEGIN IMMEDIATE")
      try assertOwnership()
      let now = Date().timeIntervalSince1970
      var inserted = false
      let aliases = notificationAliases(notification)
      var resolvedMessageID = try messageID(matching: [notification.eventID])
      if resolvedMessageID == nil, let message = message {
        let observedAt = notification.deliveredAt.timeIntervalSince1970
        try insertConversation(group: message.group, now: now)
        let resolvedConversationID = try conversationID(for: message.group)
        inserted = try insertMessage(
          notification: notification,
          message: message,
          conversationID: resolvedConversationID,
          observedAt: observedAt,
          now: now
        )
        resolvedMessageID = try messageID(matching: [notification.eventID])
        if inserted {
          try updateConversation(
            id: resolvedConversationID,
            observedAt: observedAt,
            now: now
          )
        }
      }
      if let resolvedMessageID = resolvedMessageID {
        for alias in aliases {
          // Quarantine records a durable ambiguity in the alias namespace;
          // it does not invalidate this notification's exact canonical row.
          // Normal ingestion must retain the deny-set and checkpoint the
          // revision while safely omitting only that derived alias.
          if try aliasIsQuarantined(alias) { continue }
          try insertAlias(alias, messageID: resolvedMessageID, now: now)
        }
      }
      try updateCheckpoint(
        timestamp: notification.updateTimestamp,
        recordID: notification.recordID,
        now: now
      )
      try execute("COMMIT")
      return inserted
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  func legacyPrefixAliasScanIfNeeded() throws -> LegacyPrefixAliasScan? {
    do {
      try execute("BEGIN IMMEDIATE")
      try assertOwnership()
      // Version 302 was emitted by an intermediate build before folded
      // multi-revision provenance was understood.  Only the superseding audit
      // marker proves this store has passed the per-survivor checks below.
      if try migrationApplied(Self.legacyPrefixAliasAuditVersion) {
        try execute("COMMIT")
        return nil
      }
      let hadLegacyPrefixAliasMarker = try migrationApplied(
        Self.legacyPrefixAliasMigrationVersion
      )
      // Version 2 only upgrades rows whose pre-canonical provenance has already
      // been verified and consolidated by version 1.  Never let a pending v1
      // migration become hidden behind the newer marker.
      guard try migrationApplied(Self.legacyAliasMigrationVersion) else {
        try execute("COMMIT")
        return nil
      }
      let version1AppliedAt = try migrationAppliedAt(
        Self.legacyAliasMigrationVersion
      )
      let quarantineRows = try prepare(
        "SELECT alias_event_id FROM message_event_alias_quarantine ORDER BY alias_event_id"
      )
      defer { sqlite3_finalize(quarantineRows) }
      var quarantinedEventIDs = Set<String>()
      while true {
        let step = sqlite3_step(quarantineRows)
        if step == SQLITE_DONE { break }
        guard step == SQLITE_ROW else { throw sqliteStorageError(database) }
        quarantinedEventIDs.insert(String(cString: sqlite3_column_text(quarantineRows, 0)))
      }
      let rows = try prepare(
        """
        SELECT m.id, m.event_id, m.source_sequence, m.group_name,
          COALESCE(m.sender_display_name, ''), m.content, a.alias_event_id,
          a.created_at,
          EXISTS(
            SELECT 1 FROM message_legacy_alias_provenance p
            WHERE p.message_id = m.id AND p.version IN (?, ?)
          )
        FROM messages m
        JOIN message_event_aliases a ON a.message_id = m.id
        WHERE m.source_sequence IS NOT NULL
        ORDER BY m.id, a.alias_event_id
        """
      )
      defer { sqlite3_finalize(rows) }
      try bindInt64(Self.oldLegacyAliasProvenanceVersion, to: rows, at: 1)
      try bindInt64(Self.legacyAliasProvenanceVersion, to: rows, at: 2)
      var seeds: [Int64: LegacyPrefixAliasSeed] = [:]
      while true {
        let step = sqlite3_step(rows)
        if step == SQLITE_DONE { break }
        guard step == SQLITE_ROW else { throw sqliteStorageError(database) }
        let messageID = sqlite3_column_int64(rows, 0)
        let sourceSequence = sqlite3_column_int64(rows, 2)
        let alias = String(cString: sqlite3_column_text(rows, 6))
        let createdAtType = sqlite3_column_type(rows, 7)
        let createdAt = sqlite3_column_double(rows, 7)
        let hasValidCreatedAt = (createdAtType == SQLITE_FLOAT
          || createdAtType == SQLITE_INTEGER) && createdAt.isFinite
        let isStandalone = precanonicalIdentity(
          eventID: alias,
          sourceSequence: sourceSequence
        ) != nil
        if var seed = seeds[messageID] {
          seed.retainedEventIDs.append(alias)
          if hasValidCreatedAt { seed.retainedEventCreatedAt[alias] = createdAt }
          if isStandalone { seed.standaloneEventIDs.append(alias) }
          seeds[messageID] = seed
        } else {
          seeds[messageID] = LegacyPrefixAliasSeed(
            messageID: messageID,
            canonicalEventID: String(cString: sqlite3_column_text(rows, 1)),
            sourceSequence: sourceSequence,
            group: String(cString: sqlite3_column_text(rows, 3)),
            sender: String(cString: sqlite3_column_text(rows, 4)),
            content: String(cString: sqlite3_column_text(rows, 5)),
            standaloneEventIDs: isStandalone ? [alias] : [],
            retainedEventIDs: [alias],
            retainedEventCreatedAt: hasValidCreatedAt ? [alias: createdAt] : [:],
            hasCompleteRevisionProvenance: sqlite3_column_int(rows, 8) == 1
          )
        }
      }

      var candidates: [LegacyPrefixAliasCandidate] = []
      var unresolvedMessageIDs = Set<Int64>()
      for messageID in seeds.keys.sorted() {
        guard let seed = seeds[messageID] else { continue }
        guard !seed.standaloneEventIDs.isEmpty else { continue }
        // A pre-audit version 302 may itself have manufactured the twelve IDs
        // used to recognize baa877b's single-revision semantic witness.  Once
        // that old marker exists, only the transaction-bound per-survivor row
        // can distinguish original version-1 evidence from later pollution.
        if hadLegacyPrefixAliasMarker && !seed.hasCompleteRevisionProvenance {
          unresolvedMessageIDs.insert(messageID)
          continue
        }
        // Older version-1 stores kept each standalone source fingerprint but
        // only one group/sender/content snapshot on the canonical survivor.
        // The source revision used by version 1 also contributes its own
        // fingerprint, so more than one retained fingerprint proves that at
        // least one revision's semantic fields were folded away.  Current
        // version-1 writes a per-survivor provenance row in the same transaction
        // as its complete alias set; a global marker would be unsafe after a
        // partially completed migration from an older build.
        guard seed.hasCompleteRevisionProvenance
          || Set(seed.standaloneEventIDs).count == 1
        else {
          unresolvedMessageIDs.insert(messageID)
          continue
        }
        let identities = seed.standaloneEventIDs.compactMap {
          precanonicalIdentity(eventID: $0, sourceSequence: seed.sourceSequence)
        }
        let recordIDs = Set(identities.map { $0.recordID })
        let storageBytes = Set(identities.map { $0.uuidStorageBytesHex })
        guard recordIDs.count == 1, storageBytes.count == 1,
          let recordID = recordIDs.first,
          let uuidStorageBytesHex = storageBytes.first
        else {
          unresolvedMessageIDs.insert(messageID)
          continue
        }
        candidates.append(
          LegacyPrefixAliasCandidate(
            messageID: seed.messageID,
            recordID: recordID,
            canonicalEventID: seed.canonicalEventID,
            uuidStorageBytesHex: uuidStorageBytesHex,
            group: seed.group,
            sender: seed.sender,
            content: seed.content,
            standaloneEventIDs: seed.standaloneEventIDs,
            retainedEventIDs: seed.retainedEventIDs,
            retainedEventCreatedAt: seed.retainedEventCreatedAt,
            version1AppliedAt: version1AppliedAt,
            requiresVersion1SemanticWitness: !seed.hasCompleteRevisionProvenance
          )
        )
      }
      try execute("COMMIT")
      return LegacyPrefixAliasScan(
        candidates: candidates,
        unresolvedMessageIDs: unresolvedMessageIDs,
        quarantinedEventIDs: quarantinedEventIDs
      )
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  func addLegacyPrefixAliases(
    _ notification: StoredNotification,
    candidate: LegacyPrefixAliasCandidate,
    aliases: [String]
  ) throws -> Bool {
    do {
      try execute("BEGIN IMMEDIATE")
      try assertOwnership()
      guard candidate.recordID == notification.recordID,
        candidate.uuidStorageBytesHex == notification.uuidStorageBytesHex,
        let eventSeed = notification.stableUUID,
        !eventSeed.isEmpty,
        notification.eventID == stableHash("notification|\(eventSeed)"),
        candidate.canonicalEventID == notification.eventID,
        try messageID(matching: [candidate.canonicalEventID]) == candidate.messageID
      else {
        try execute("COMMIT")
        return false
      }
      for standaloneEventID in candidate.standaloneEventIDs {
        guard try messageID(matching: [standaloneEventID]) == candidate.messageID else {
          try execute("COMMIT")
          return false
        }
      }
      let protectedAliases = Set(
        notificationAliases(notification)
          + candidate.standaloneEventIDs
          + [candidate.canonicalEventID]
      )
      for protectedAlias in protectedAliases {
        if try aliasIsQuarantined(protectedAlias) {
          try execute("ROLLBACK")
          return false
        }
      }
      let activeAliases = try aliases.filter {
        !(try aliasIsQuarantined($0))
      }

      // Preflight every historical and current compatibility ID before any
      // insert.  A recovered alias must never steal exact lookup precedence.
      for alias in activeAliases {
        if let resolvedMessageID = try messageID(matching: [alias]),
          resolvedMessageID != candidate.messageID
        {
          try execute("ROLLBACK")
          return false
        }
      }
      let now = Date().timeIntervalSince1970
      for alias in activeAliases where alias != candidate.canonicalEventID {
        try insertAlias(alias, messageID: candidate.messageID, now: now)
      }
      for alias in activeAliases {
        guard try messageID(matching: [alias]) == candidate.messageID else {
          try execute("ROLLBACK")
          return false
        }
      }
      try execute("COMMIT")
      return true
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  func completeLegacyPrefixAliasMigration() throws {
    do {
      try execute("BEGIN IMMEDIATE")
      try assertOwnership()
      guard try migrationApplied(Self.legacyAliasMigrationVersion) else {
        try execute("COMMIT")
        return
      }
      let now = Date().timeIntervalSince1970
      try recordMigration(Self.legacyPrefixAliasMigrationVersion, at: now)
      try recordMigration(Self.legacyPrefixAliasAuditVersion, at: now)
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  func planLegacyAliasConsolidation(
    _ notification: StoredNotification,
    message: GroupMessage,
    candidates: [LegacyAliasCandidate],
    deadline: Date? = nil,
    timeout: TimeInterval = 0
  ) throws -> LegacyAliasConsolidationPlan? {
    guard !candidates.isEmpty,
      candidates.allSatisfy({ $0.recordID == notification.recordID }),
      let uuid = notification.stableUUID,
      !uuid.isEmpty,
      candidates.allSatisfy({
        $0.uuidStorageBytesHex == notification.uuidStorageBytesHex
      }),
      candidates.allSatisfy({
        !$0.hasPartialLegacyProvenance
          || $0.storedEventID == notification.eventID
      }),
      candidates.allSatisfy({ candidate in
        precanonicalIdentity(
          eventID: candidate.legacyEventID,
          sourceSequence: candidate.recordID
        ) != nil || (
          candidate.legacyEventID == candidate.storedEventID
            && candidate.storedEventID == notification.eventID
        )
      }),
      notification.eventID == stableHash("notification|\(uuid)")
    else {
      return nil
    }

    var aliases = notificationAliases(notification)
    var protectedAliases = Set(aliases)
    for candidate in candidates {
      if let deadline = deadline, Date() >= deadline {
        throw ListenerError.timedOut(timeout)
      }
      aliases.append(candidate.storedEventID)
      aliases.append(candidate.legacyEventID)
      aliases.append(contentsOf: candidate.retainedAliases)
      protectedAliases.insert(candidate.storedEventID)
      protectedAliases.insert(candidate.legacyEventID)
      for retainedAlias in candidate.retainedAliases where
        precanonicalIdentity(
          eventID: retainedAlias,
          sourceSequence: candidate.recordID
        ) != nil
      {
        protectedAliases.insert(retainedAlias)
      }
      aliases.append(contentsOf: legacyNativeCompatibilityEventIDs(
        eventSeed: uuid,
        group: candidate.group,
        sender: candidate.sender,
        content: candidate.content
      ))
    }
    if let deadline = deadline, Date() >= deadline {
      throw ListenerError.timedOut(timeout)
    }
    var seen = Set<String>()
    aliases = aliases.filter { !$0.isEmpty && seen.insert($0).inserted }
    let candidateIDs = Set(candidates.map(\.messageID))
    guard let survivorID = candidateIDs.min() else { return nil }
    return LegacyAliasConsolidationPlan(
      notification: notification,
      message: message,
      candidates: candidates,
      aliases: aliases,
      protectedAliases: protectedAliases,
      candidateIDs: candidateIDs,
      survivorID: survivorID,
      recoversLegacyPartialState: candidates.contains {
        $0.hasPartialLegacyProvenance
      }
    )
  }

  func consolidateLegacyRevisionPlans(
    _ plans: [LegacyAliasConsolidationPlan],
    expectedMessageIDs: Set<Int64>,
    deadline: Date?,
    timeout: TimeInterval
  ) throws -> Set<Int64> {
    do {
      try execute("BEGIN IMMEDIATE")
      try assertOwnership()
      guard !plans.isEmpty, !expectedMessageIDs.isEmpty,
        !(try migrationApplied(Self.legacyAliasMigrationVersion))
      else {
        try execute("ROLLBACK")
        return []
      }

      // Recompute every source-derived plan inside the write transaction and
      // prove the plan set is a complete, disjoint cover before the first
      // message, alias, provenance, or migration-marker mutation.
      var plannedMessageIDs = Set<Int64>()
      var ownerPlans: [(ownerID: Int64, aliases: [String])] = []
      for plan in plans {
        if let deadline = deadline, Date() >= deadline {
          throw ListenerError.timedOut(timeout)
        }
        guard let recomputed = try planLegacyAliasConsolidation(
            plan.notification,
            message: plan.message,
            candidates: plan.candidates,
            deadline: deadline,
            timeout: timeout
          ),
          recomputed.aliases == plan.aliases,
          recomputed.protectedAliases == plan.protectedAliases,
          recomputed.candidateIDs == plan.candidateIDs,
          recomputed.survivorID == plan.survivorID,
          recomputed.recoversLegacyPartialState == plan.recoversLegacyPartialState,
          plannedMessageIDs.isDisjoint(with: plan.candidateIDs)
        else {
          try execute("ROLLBACK")
          return []
        }
        plannedMessageIDs.formUnion(plan.candidateIDs)
        ownerPlans.append((ownerID: plan.survivorID, aliases: plan.aliases))
      }
      guard plannedMessageIDs == expectedMessageIDs else {
        try execute("ROLLBACK")
        return []
      }

      let aliasOwners = legacyAliasOwners(ownerPlans)
      let ambiguousAliases = Set(aliasOwners.compactMap { alias, owners in
        owners.count > 1 ? alias : nil
      })
      let protectedAliases = plans.reduce(into: Set<String>()) {
        $0.formUnion($1.protectedAliases)
      }
      let recoversLegacyPartialState = plans.contains {
        $0.recoversLegacyPartialState
      }
      var quarantinedAliases = Set<String>()
      if !ambiguousAliases.isEmpty {
        guard recoversLegacyPartialState,
          ambiguousAliases.isDisjoint(with: protectedAliases)
        else {
          try execute("ROLLBACK")
          return []
        }
        let exactOwner = try prepare(
          "SELECT id FROM messages WHERE event_id = ? LIMIT 1"
        )
        defer { sqlite3_finalize(exactOwner) }
        let aliasOwner = try prepare(
          "SELECT message_id FROM message_event_aliases WHERE alias_event_id = ? LIMIT 1"
        )
        defer { sqlite3_finalize(aliasOwner) }
        let recoveredCandidateIDs = plans.filter {
          $0.recoversLegacyPartialState
        }.reduce(into: Set<Int64>()) {
          $0.formUnion($1.candidateIDs)
        }
        for alias in ambiguousAliases {
          if let deadline = deadline, Date() >= deadline {
            throw ListenerError.timedOut(timeout)
          }
          sqlite3_reset(exactOwner)
          sqlite3_clear_bindings(exactOwner)
          try bindText(alias, to: exactOwner, at: 1)
          let exactStep = sqlite3_step(exactOwner)
          guard exactStep == SQLITE_DONE else {
            if exactStep != SQLITE_ROW { throw sqliteStorageError(database) }
            try execute("ROLLBACK")
            return []
          }

          sqlite3_reset(aliasOwner)
          sqlite3_clear_bindings(aliasOwner)
          try bindText(alias, to: aliasOwner, at: 1)
          let aliasStep = sqlite3_step(aliasOwner)
          guard aliasStep == SQLITE_ROW else {
            if aliasStep != SQLITE_DONE { throw sqliteStorageError(database) }
            try execute("ROLLBACK")
            return []
          }
          let currentOwner = sqlite3_column_int64(aliasOwner, 0)
          guard plannedMessageIDs.contains(currentOwner),
            aliasOwners[alias]?.contains(currentOwner) == true,
            recoveredCandidateIDs.contains(currentOwner)
          else {
            try execute("ROLLBACK")
            return []
          }
          quarantinedAliases.insert(alias)
        }
      }

      let candidateLookup = try prepare(
        """
        SELECT event_id, source_sequence, group_name,
          COALESCE(sender_display_name, ''), content, conversation_id
        FROM messages
        WHERE id = ?
        LIMIT 1
        """
      )
      defer { sqlite3_finalize(candidateLookup) }
      var affectedConversationIDs = Set<Int64>()
      for plan in plans {
        for candidate in plan.candidates {
          if let deadline = deadline, Date() >= deadline {
            throw ListenerError.timedOut(timeout)
          }
          sqlite3_reset(candidateLookup)
          sqlite3_clear_bindings(candidateLookup)
          try bindInt64(candidate.messageID, to: candidateLookup, at: 1)
          let step = sqlite3_step(candidateLookup)
          guard step == SQLITE_ROW else {
            if step != SQLITE_DONE { throw sqliteStorageError(database) }
            try execute("ROLLBACK")
            return []
          }
          guard sqlite3_column_type(candidateLookup, 0) == SQLITE_TEXT,
            sqlite3_column_type(candidateLookup, 1) != SQLITE_NULL,
            String(cString: sqlite3_column_text(candidateLookup, 0))
              == candidate.storedEventID,
            sqlite3_column_int64(candidateLookup, 1) == candidate.recordID,
            String(cString: sqlite3_column_text(candidateLookup, 2)) == candidate.group,
            String(cString: sqlite3_column_text(candidateLookup, 3)) == candidate.sender,
            String(cString: sqlite3_column_text(candidateLookup, 4)) == candidate.content
          else {
            try execute("ROLLBACK")
            return []
          }
          affectedConversationIDs.insert(sqlite3_column_int64(candidateLookup, 5))
          guard try messageID(matching: [candidate.legacyEventID]) == candidate.messageID
          else {
            try execute("ROLLBACK")
            return []
          }
          for retainedAlias in candidate.retainedAliases where
            !quarantinedAliases.contains(retainedAlias)
          {
            guard try messageID(matching: [retainedAlias]) == candidate.messageID else {
              try execute("ROLLBACK")
              return []
            }
          }
        }
      }

      // Exact event rows and previously retained aliases share one lookup
      // namespace.  Preflight every owner against that namespace before any
      // owner can claim an alias or become canonical.
      for plan in plans {
        for alias in plan.aliases where !quarantinedAliases.contains(alias) {
          if let deadline = deadline, Date() >= deadline {
            throw ListenerError.timedOut(timeout)
          }
          if let resolvedMessageID = try messageID(matching: [alias]),
            !plan.candidateIDs.contains(resolvedMessageID)
          {
            try execute("ROLLBACK")
            return []
          }
        }
      }

      let now = Date().timeIntervalSince1970
      if !quarantinedAliases.isEmpty {
        let quarantine = try prepare(
          """
          INSERT INTO message_event_alias_quarantine(
            alias_event_id, version, claimant_message_ids_json, quarantined_at
          ) VALUES (?, ?, ?, ?)
          """
        )
        defer { sqlite3_finalize(quarantine) }
        let deleteAlias = try prepare(
          "DELETE FROM message_event_aliases WHERE alias_event_id = ?"
        )
        defer { sqlite3_finalize(deleteAlias) }
        for alias in quarantinedAliases.sorted() {
          guard let ownerIDs = aliasOwners[alias] else {
            try execute("ROLLBACK")
            return []
          }
          let claimantJSON = "[" + ownerIDs.sorted().map(String.init).joined(
            separator: ","
          ) + "]"
          sqlite3_reset(quarantine)
          sqlite3_clear_bindings(quarantine)
          try bindText(alias, to: quarantine, at: 1)
          try bindInt64(Self.legacyAliasProvenanceVersion, to: quarantine, at: 2)
          try bindText(claimantJSON, to: quarantine, at: 3)
          try bindDouble(now, to: quarantine, at: 4)
          guard sqlite3_step(quarantine) == SQLITE_DONE,
            sqlite3_changes(database) == 1
          else {
            throw sqliteStorageError(database)
          }

          sqlite3_reset(deleteAlias)
          sqlite3_clear_bindings(deleteAlias)
          try bindText(alias, to: deleteAlias, at: 1)
          guard sqlite3_step(deleteAlias) == SQLITE_DONE,
            sqlite3_changes(database) == 1
          else {
            throw sqliteStorageError(database)
          }
        }
      }
      let updateSurvivor = try prepare(
        """
        UPDATE messages
        SET event_id = ?, conversation_id = ?, group_name = ?,
          sender_display_name = ?, sender_stable_id = NULL, content = ?,
          message_type = ?, observed_at = ?, source_sequence = ?,
          attachments_json = X'5B5D', attachment_count = 0,
          sender_confidence = 'notification_payload', is_from_self = 0,
          record_version = record_version + 1
        WHERE id = ?
        """
      )
      defer { sqlite3_finalize(updateSurvivor) }
      let moveAliases = try prepare(
        "UPDATE message_event_aliases SET message_id = ? WHERE message_id = ?"
      )
      defer { sqlite3_finalize(moveAliases) }
      let deleteMessage = try prepare("DELETE FROM messages WHERE id = ?")
      defer { sqlite3_finalize(deleteMessage) }
      let provenance = try prepare(
        """
        INSERT OR REPLACE INTO message_legacy_alias_provenance(
          message_id, version, completed_at
        ) VALUES (?, ?, ?)
        """
      )
      defer { sqlite3_finalize(provenance) }

      for plan in plans.sorted(by: {
        $0.survivorID < $1.survivorID
      }) {
        if let deadline = deadline, Date() >= deadline {
          throw ListenerError.timedOut(timeout)
        }
        let survivorID = plan.survivorID
        try insertConversation(group: plan.message.group, now: now)
        let currentConversationID = try conversationID(for: plan.message.group)
        affectedConversationIDs.insert(currentConversationID)

        // A failed 65f migration can be followed by safety replay, leaving a
        // newer canonical duplicate beside the older pre-canonical survivor.
        // Vacate that UNIQUE(event_id) slot before refreshing the deterministic
        // oldest survivor, while retaining all of the duplicate's aliases.
        let canonicalDuplicateIDs = Set(plan.candidates.compactMap { candidate in
          candidate.messageID != survivorID
            && candidate.storedEventID == plan.notification.eventID
            ? candidate.messageID
            : nil
        })
        for duplicateID in canonicalDuplicateIDs.sorted() {
          sqlite3_reset(moveAliases)
          sqlite3_clear_bindings(moveAliases)
          try bindInt64(survivorID, to: moveAliases, at: 1)
          try bindInt64(duplicateID, to: moveAliases, at: 2)
          guard sqlite3_step(moveAliases) == SQLITE_DONE else {
            throw sqliteStorageError(database)
          }
          sqlite3_reset(deleteMessage)
          sqlite3_clear_bindings(deleteMessage)
          try bindInt64(duplicateID, to: deleteMessage, at: 1)
          guard sqlite3_step(deleteMessage) == SQLITE_DONE,
            sqlite3_changes(database) == 1
          else {
            throw sqliteStorageError(database)
          }
        }

        // Keep the oldest row stable for callers that persisted its database
        // ID, while refreshing all notification-derived fields from the
        // source-verified current revision.
        sqlite3_reset(updateSurvivor)
        sqlite3_clear_bindings(updateSurvivor)
        try bindText(plan.notification.eventID, to: updateSurvivor, at: 1)
        try bindInt64(currentConversationID, to: updateSurvivor, at: 2)
        try bindText(plan.message.group, to: updateSurvivor, at: 3)
        try bindText(plan.message.sender, to: updateSurvivor, at: 4)
        try bindText(plan.message.content, to: updateSurvivor, at: 5)
        try bindText(messageType(for: plan.message.content), to: updateSurvivor, at: 6)
        try bindDouble(
          plan.notification.deliveredAt.timeIntervalSince1970,
          to: updateSurvivor,
          at: 7
        )
        try bindInt64(plan.notification.recordID, to: updateSurvivor, at: 8)
        try bindInt64(survivorID, to: updateSurvivor, at: 9)
        guard sqlite3_step(updateSurvivor) == SQLITE_DONE,
          sqlite3_changes(database) == 1
        else {
          throw sqliteStorageError(database)
        }

        for duplicateID in plan.candidateIDs.sorted() where
          duplicateID != survivorID && !canonicalDuplicateIDs.contains(duplicateID)
        {
          if let deadline = deadline, Date() >= deadline {
            throw ListenerError.timedOut(timeout)
          }
          sqlite3_reset(moveAliases)
          sqlite3_clear_bindings(moveAliases)
          try bindInt64(survivorID, to: moveAliases, at: 1)
          try bindInt64(duplicateID, to: moveAliases, at: 2)
          guard sqlite3_step(moveAliases) == SQLITE_DONE else {
            throw sqliteStorageError(database)
          }

          sqlite3_reset(deleteMessage)
          sqlite3_clear_bindings(deleteMessage)
          try bindInt64(duplicateID, to: deleteMessage, at: 1)
          guard sqlite3_step(deleteMessage) == SQLITE_DONE,
            sqlite3_changes(database) == 1
          else {
            throw sqliteStorageError(database)
          }
        }

        for alias in plan.aliases where
          alias != plan.notification.eventID && !quarantinedAliases.contains(alias)
        {
          if let deadline = deadline, Date() >= deadline {
            throw ListenerError.timedOut(timeout)
          }
          try insertAlias(alias, messageID: survivorID, now: now)
        }
        for alias in plan.aliases where !quarantinedAliases.contains(alias) {
          if let deadline = deadline, Date() >= deadline {
            throw ListenerError.timedOut(timeout)
          }
          guard try messageID(matching: [alias]) == survivorID else {
            try execute("ROLLBACK")
            return []
          }
        }

        // Per-survivor proof and marker 301 are committed together with every
        // owner, so a crash cannot expose a partially certified owner set.
        sqlite3_reset(provenance)
        sqlite3_clear_bindings(provenance)
        try bindInt64(survivorID, to: provenance, at: 1)
        try bindInt64(Self.legacyAliasProvenanceVersion, to: provenance, at: 2)
        try bindDouble(now, to: provenance, at: 3)
        guard sqlite3_step(provenance) == SQLITE_DONE else {
          throw sqliteStorageError(database)
        }
      }

      let repairConversation = try prepare(
        """
        UPDATE conversations
        SET updated_at = ?,
          last_message_at = (
            SELECT MAX(observed_at) FROM messages WHERE conversation_id = conversations.id
          ),
          message_count = (
            SELECT COUNT(*) FROM messages WHERE conversation_id = conversations.id
          )
        WHERE id = ?
        """
      )
      defer { sqlite3_finalize(repairConversation) }
      for conversationID in affectedConversationIDs {
        if let deadline = deadline, Date() >= deadline {
          throw ListenerError.timedOut(timeout)
        }
        sqlite3_reset(repairConversation)
        sqlite3_clear_bindings(repairConversation)
        try bindDouble(now, to: repairConversation, at: 1)
        try bindInt64(conversationID, to: repairConversation, at: 2)
        guard sqlite3_step(repairConversation) == SQLITE_DONE else {
          throw sqliteStorageError(database)
        }
      }

      if let deadline = deadline, Date() >= deadline {
        throw ListenerError.timedOut(timeout)
      }
      if recoversLegacyPartialState {
        try recordMigration(Self.legacyPartialRecoveryVersion, at: now)
      }
      try recordMigration(Self.legacyAliasMigrationVersion, at: now)
      try execute("COMMIT")
      return expectedMessageIDs
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  func saveBaseline(_ cursor: NotificationCursor) throws {
    do {
      try execute("BEGIN IMMEDIATE")
      try assertOwnership()
      let now = Date().timeIntervalSince1970
      try updateCheckpoint(timestamp: cursor.timestamp, recordID: cursor.recordID, now: now)
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  func heartbeat(at timestamp: Double) throws {
    let statement = try prepare(
      """
      UPDATE listener_state
      SET heartbeat_at = ?, updated_at = ?
      WHERE singleton_id = 1 AND instance_id = ?
      """
    )
    defer { sqlite3_finalize(statement) }
    try bindDouble(timestamp, to: statement, at: 1)
    try bindDouble(timestamp, to: statement, at: 2)
    try bindText(instanceID, to: statement, at: 3)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteStorageError(database) }
    guard sqlite3_changes(database) == 1 else {
      throw ListenerError.storage("监听实例已被替换")
    }
  }

  func markSourceUnavailable(at timestamp: Double) throws {
    let statement = try prepare(
      """
      UPDATE listener_state
      SET heartbeat_at = 0, updated_at = ?
      WHERE singleton_id = 1 AND instance_id = ?
      """
    )
    defer { sqlite3_finalize(statement) }
    try bindDouble(timestamp, to: statement, at: 1)
    try bindText(instanceID, to: statement, at: 2)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteStorageError(database) }
    guard sqlite3_changes(database) == 1 else {
      throw ListenerError.storage("监听实例已被替换")
    }
  }

  func markReady() throws {
    try heartbeat(at: Date().timeIntervalSince1970)
  }

  private func execute(_ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &error)
    if let error = error { sqlite3_free(error) }
    guard result == SQLITE_OK else { throw sqliteStorageError(database) }
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let preparedStatement = statement
    else {
      throw sqliteStorageError(database)
    }
    return preparedStatement
  }

  private func bindText(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
    let result = value.withCString {
      sqlite3_bind_text(statement, index, $0, -1, Self.sqliteTransientDestructor)
    }
    guard result == SQLITE_OK else { throw sqliteStorageError(database) }
  }

  private func bindInt64(_ value: Int64, to statement: OpaquePointer, at index: Int32) throws {
    guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
      throw sqliteStorageError(database)
    }
  }

  private func bindDouble(_ value: Double, to statement: OpaquePointer, at index: Int32) throws {
    guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
      throw sqliteStorageError(database)
    }
  }

  private func insertConversation(group: String, now: Double) throws {
    let statement = try prepare(
      """
      INSERT INTO conversations(source, group_name, created_at, updated_at)
      VALUES ('wecom_notification', ?, ?, ?)
      ON CONFLICT(source, group_name) DO NOTHING
      """
    )
    defer { sqlite3_finalize(statement) }
    try bindText(group, to: statement, at: 1)
    try bindDouble(now, to: statement, at: 2)
    try bindDouble(now, to: statement, at: 3)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw sqliteStorageError(database)
    }
  }

  private func conversationID(for group: String) throws -> Int64 {
    let statement = try prepare(
      "SELECT id FROM conversations WHERE source = 'wecom_notification' AND group_name = ?"
    )
    defer { sqlite3_finalize(statement) }
    try bindText(group, to: statement, at: 1)
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw sqliteStorageError(database)
    }
    return sqlite3_column_int64(statement, 0)
  }

  private func insertMessage(
    notification: StoredNotification,
    message: GroupMessage,
    conversationID: Int64,
    observedAt: Double,
    now: Double
  ) throws -> Bool {
    let statement = try prepare(
      """
      INSERT OR IGNORE INTO messages(
        event_id, conversation_id, group_name, sender_display_name, content,
        message_type, observed_at, source_sequence, inserted_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """
    )
    defer { sqlite3_finalize(statement) }
    try bindText(notification.eventID, to: statement, at: 1)
    try bindInt64(conversationID, to: statement, at: 2)
    try bindText(message.group, to: statement, at: 3)
    try bindText(message.sender, to: statement, at: 4)
    try bindText(message.content, to: statement, at: 5)
    try bindText(messageType(for: message.content), to: statement, at: 6)
    try bindDouble(observedAt, to: statement, at: 7)
    try bindInt64(notification.recordID, to: statement, at: 8)
    try bindDouble(now, to: statement, at: 9)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw sqliteStorageError(database)
    }
    return sqlite3_changes(database) == 1
  }

  private func notificationAliases(_ notification: StoredNotification) -> [String] {
    var values = [notification.eventID]
    guard notification.hasStableUUID else { return values }
    values.append(notification.legacyLANEventID)
    if let legacyNativeEventID = notification.legacyNativeEventID {
      values.append(legacyNativeEventID)
    }
    var seen = Set<String>()
    return values.filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  private func messageID(matching eventIDs: [String]) throws -> Int64? {
    let exactStatement = try prepare("SELECT id FROM messages WHERE event_id = ? LIMIT 1")
    defer { sqlite3_finalize(exactStatement) }
    let aliasStatement = try prepare(
      """
      SELECT aliases.message_id
      FROM message_event_aliases aliases
      WHERE aliases.alias_event_id = ?
        AND NOT EXISTS(
          SELECT 1 FROM message_event_alias_quarantine quarantine
          WHERE quarantine.alias_event_id = aliases.alias_event_id
        )
      LIMIT 1
      """
    )
    defer { sqlite3_finalize(aliasStatement) }
    for eventID in eventIDs {
      sqlite3_reset(exactStatement)
      sqlite3_clear_bindings(exactStatement)
      try bindText(eventID, to: exactStatement, at: 1)
      let exactStep = sqlite3_step(exactStatement)
      if exactStep == SQLITE_ROW { return sqlite3_column_int64(exactStatement, 0) }
      guard exactStep == SQLITE_DONE else { throw sqliteStorageError(database) }

      sqlite3_reset(aliasStatement)
      sqlite3_clear_bindings(aliasStatement)
      try bindText(eventID, to: aliasStatement, at: 1)
      let aliasStep = sqlite3_step(aliasStatement)
      if aliasStep == SQLITE_ROW { return sqlite3_column_int64(aliasStatement, 0) }
      guard aliasStep == SQLITE_DONE else { throw sqliteStorageError(database) }
    }
    return nil
  }

  private func aliasIsQuarantined(_ alias: String) throws -> Bool {
    let statement = try prepare(
      "SELECT 1 FROM message_event_alias_quarantine WHERE alias_event_id = ? LIMIT 1"
    )
    defer { sqlite3_finalize(statement) }
    try bindText(alias, to: statement, at: 1)
    let step = sqlite3_step(statement)
    if step == SQLITE_ROW { return true }
    guard step == SQLITE_DONE else { throw sqliteStorageError(database) }
    return false
  }

  private func updateConversation(id: Int64, observedAt: Double, now: Double) throws {
    let statement = try prepare(
      """
      UPDATE conversations
      SET updated_at = ?,
        last_message_at = CASE
          WHEN last_message_at IS NULL OR last_message_at < ? THEN ?
          ELSE last_message_at
        END,
        message_count = message_count + 1
      WHERE id = ?
      """
    )
    defer { sqlite3_finalize(statement) }
    try bindDouble(now, to: statement, at: 1)
    try bindDouble(observedAt, to: statement, at: 2)
    try bindDouble(observedAt, to: statement, at: 3)
    try bindInt64(id, to: statement, at: 4)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw sqliteStorageError(database)
    }
  }

  private func ensureListenerStateColumns() throws {
    let statement = try prepare("PRAGMA table_info(listener_state)")
    defer { sqlite3_finalize(statement) }
    var columns = Set<String>()
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else { throw sqliteStorageError(database) }
      if let name = sqlite3_column_text(statement, 1) {
        columns.insert(String(cString: name))
      }
    }
    if !columns.contains("source_key") {
      try execute("ALTER TABLE listener_state ADD COLUMN source_key TEXT")
    }
  }

  private func listenerSourceState() throws -> (
    sourceKey: String?, cursorTimestampIsNull: Bool, cursorRecordIDIsNull: Bool
  ) {
    let statement = try prepare(
      """
      SELECT source_key, cursor_timestamp, cursor_record_id
      FROM listener_state
      WHERE singleton_id = 1 AND instance_id = ?
      """
    )
    defer { sqlite3_finalize(statement) }
    try bindText(instanceID, to: statement, at: 1)
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw ListenerError.storage("监听实例已被替换")
    }
    let sourceKey = sqlite3_column_type(statement, 0) == SQLITE_TEXT
      ? String(cString: sqlite3_column_text(statement, 0))
      : nil
    return (
      sourceKey: sourceKey,
      cursorTimestampIsNull: sqlite3_column_type(statement, 1) == SQLITE_NULL,
      cursorRecordIDIsNull: sqlite3_column_type(statement, 2) == SQLITE_NULL
    )
  }

  private func migrationApplied(_ version: Int64) throws -> Bool {
    let statement = try prepare(
      "SELECT 1 FROM schema_migrations WHERE version = ? LIMIT 1"
    )
    defer { sqlite3_finalize(statement) }
    try bindInt64(version, to: statement, at: 1)
    let step = sqlite3_step(statement)
    if step == SQLITE_ROW { return true }
    guard step == SQLITE_DONE else { throw sqliteStorageError(database) }
    return false
  }

  private func migrationAppliedAt(_ version: Int64) throws -> Double? {
    let statement = try prepare(
      "SELECT applied_at FROM schema_migrations WHERE version = ? LIMIT 1"
    )
    defer { sqlite3_finalize(statement) }
    try bindInt64(version, to: statement, at: 1)
    let step = sqlite3_step(statement)
    if step == SQLITE_DONE { return nil }
    guard step == SQLITE_ROW else { throw sqliteStorageError(database) }
    let valueType = sqlite3_column_type(statement, 0)
    guard valueType == SQLITE_FLOAT || valueType == SQLITE_INTEGER else {
      return nil
    }
    let appliedAt = sqlite3_column_double(statement, 0)
    return appliedAt.isFinite ? appliedAt : nil
  }

  private func recordMigration(_ version: Int64, at appliedAt: Double) throws {
    let statement = try prepare(
      "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (?, ?)"
    )
    defer { sqlite3_finalize(statement) }
    try bindInt64(version, to: statement, at: 1)
    try bindDouble(appliedAt, to: statement, at: 2)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw sqliteStorageError(database)
    }
  }

  private func checkDeadline(_ deadline: Date?, timeout: TimeInterval) throws {
    if let deadline = deadline, Date() >= deadline {
      throw ListenerError.timedOut(timeout)
    }
  }

  private func migratePrecanonicalAliasesIfNeeded(
    deadline: Date?,
    timeout: TimeInterval
  ) throws -> LegacyAliasScan {
    if try migrationApplied(Self.legacyAliasMigrationVersion) {
      return LegacyAliasScan(candidates: [], expectedMessageIDs: [])
    }
    try checkDeadline(deadline, timeout: timeout)

    let deadlineContext: Unmanaged<SQLiteDeadlineContext>?
    if let deadline = deadline {
      let retained = Unmanaged.passRetained(
        SQLiteDeadlineContext(deadline: deadline)
      )
      sqlite3_progress_handler(
        database,
        1_000,
        sqliteDeadlineProgressCallback,
        retained.toOpaque()
      )
      deadlineContext = retained
    } else {
      deadlineContext = nil
    }
    defer {
      if let retained = deadlineContext {
        sqlite3_progress_handler(database, 0, nil, nil)
        retained.release()
      }
    }

    // A released per-owner producer could commit a canonical survivor and
    // provenance 303, then leave marker 301 absent when a later owner collided.
    // Scan exact rows, retained standalone aliases, and that old proof together
    // so the recovery owner universe cannot omit the already-converted row.
    let rows = try prepare(
      """
      SELECT m.id, m.event_id, m.source_sequence, m.group_name,
        COALESCE(m.sender_display_name, ''), m.content, a.alias_event_id,
        EXISTS(
          SELECT 1 FROM message_legacy_alias_provenance p
          WHERE p.message_id = m.id AND p.version IN (?, ?)
        )
      FROM messages m
      LEFT JOIN message_event_aliases a ON a.message_id = m.id
      ORDER BY m.id
      """
    )
    defer { sqlite3_finalize(rows) }
    try bindInt64(Self.oldLegacyAliasProvenanceVersion, to: rows, at: 1)
    try bindInt64(Self.legacyAliasProvenanceVersion, to: rows, at: 2)
    var seeds: [Int64: LegacyAliasMessageSeed] = [:]
    while true {
      let step = sqlite3_step(rows)
      delayLegacyAliasScanRowForTestIfRequested()
      try checkDeadline(deadline, timeout: timeout)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else { throw sqliteStorageError(database) }
      let messageID = sqlite3_column_int64(rows, 0)
      let alias = sqlite3_column_type(rows, 6) == SQLITE_TEXT
        ? String(cString: sqlite3_column_text(rows, 6))
        : nil
      if let seed = seeds[messageID] {
        if let alias = alias { seed.retainedAliases.append(alias) }
      } else {
        seeds[messageID] = LegacyAliasMessageSeed(
          messageID: messageID,
          storedEventID: String(cString: sqlite3_column_text(rows, 1)),
          sourceSequence: sqlite3_column_type(rows, 2) == SQLITE_NULL
            ? nil
            : sqlite3_column_int64(rows, 2),
          group: String(cString: sqlite3_column_text(rows, 3)),
          sender: String(cString: sqlite3_column_text(rows, 4)),
          content: String(cString: sqlite3_column_text(rows, 5)),
          retainedAliases: alias.map { [$0] } ?? [],
          hasPartialLegacyProvenance: sqlite3_column_int(rows, 7) == 1
        )
      }
    }

    var candidates: [LegacyAliasCandidate] = []
    var expectedMessageIDs = Set<Int64>()
    for (messageID, seed) in seeds {
      try checkDeadline(deadline, timeout: timeout)
      guard let sourceSequence = seed.sourceSequence else {
        if seed.hasPartialLegacyProvenance {
          expectedMessageIDs.insert(messageID)
        }
        continue
      }
      let storedIdentity = precanonicalIdentity(
        eventID: seed.storedEventID,
        sourceSequence: sourceSequence
      )
      if storedIdentity != nil { expectedMessageIDs.insert(messageID) }
      if seed.hasPartialLegacyProvenance {
        expectedMessageIDs.insert(messageID)
      }
      if seed.hasPartialLegacyProvenance {
        var standaloneByIdentity: [String: String] = [:]
        for alias in seed.retainedAliases {
          try checkDeadline(deadline, timeout: timeout)
          guard let identity = precanonicalIdentity(
            eventID: alias,
            sourceSequence: sourceSequence
          ) else {
            continue
          }
          let identityKey = "\(identity.recordID):\(identity.uuidStorageBytesHex)"
          if standaloneByIdentity[identityKey] == nil {
            standaloneByIdentity[identityKey] = alias
          }
        }
        if let storedIdentity = storedIdentity {
          let identityKey = "\(storedIdentity.recordID):\(storedIdentity.uuidStorageBytesHex)"
          if standaloneByIdentity[identityKey] == nil {
            standaloneByIdentity[identityKey] = seed.storedEventID
          }
        }
        guard standaloneByIdentity.count == 1,
          let identityKey = standaloneByIdentity.keys.first,
          let legacyEventID = standaloneByIdentity[identityKey],
          let identity = precanonicalIdentity(
            eventID: legacyEventID,
            sourceSequence: sourceSequence
          )
        else {
          continue
        }
        candidates.append(
          LegacyAliasCandidate(
            messageID: messageID,
            recordID: identity.recordID,
            storedEventID: seed.storedEventID,
            legacyEventID: legacyEventID,
            uuidStorageBytesHex: identity.uuidStorageBytesHex,
            group: seed.group,
            sender: seed.sender,
            content: seed.content,
            retainedAliases: seed.retainedAliases,
            hasPartialLegacyProvenance: true
          )
        )
      } else if let identity = storedIdentity {
        candidates.append(
          LegacyAliasCandidate(
            messageID: messageID,
            recordID: identity.recordID,
            storedEventID: seed.storedEventID,
            legacyEventID: seed.storedEventID,
            uuidStorageBytesHex: identity.uuidStorageBytesHex,
            group: seed.group,
            sender: seed.sender,
            content: seed.content,
            retainedAliases: seed.retainedAliases,
            hasPartialLegacyProvenance: false
          )
        )
      }
    }

    // 65f495d could continue into safety replay after its per-owner failure.
    // That replay inserts the current canonical row beside the untouched older
    // pre-canonical row.  In recovery mode, attach such a row provisionally to
    // each matching record/storage owner; the source-verified canonical hash
    // and UUID storage bytes in planLegacyAliasConsolidation must still prove
    // the one valid owner before it can enter the transaction.
    if candidates.contains(where: { $0.hasPartialLegacyProvenance }) {
      var identitiesByRecordID: [Int64: Set<String>] = [:]
      for candidate in candidates {
        try checkDeadline(deadline, timeout: timeout)
        identitiesByRecordID[candidate.recordID, default: []].insert(
          candidate.uuidStorageBytesHex
        )
      }
      for (messageID, seed) in seeds where !expectedMessageIDs.contains(messageID) {
        try checkDeadline(deadline, timeout: timeout)
        guard let sourceSequence = seed.sourceSequence,
          let storageIdentities = identitiesByRecordID[sourceSequence],
          precanonicalIdentity(
            eventID: seed.storedEventID,
            sourceSequence: sourceSequence
          ) == nil
        else {
          continue
        }
        expectedMessageIDs.insert(messageID)
        // Multiple storage identities for one record cannot all describe the
        // single current source row.  Keep the complete owner set pending
        // instead of expanding replay candidates as U×I or guessing an owner.
        guard storageIdentities.count == 1,
          let uuidStorageBytesHex = storageIdentities.first
        else {
          continue
        }
        candidates.append(
          LegacyAliasCandidate(
            messageID: messageID,
            recordID: sourceSequence,
            storedEventID: seed.storedEventID,
            legacyEventID: seed.storedEventID,
            uuidStorageBytesHex: uuidStorageBytesHex,
            group: seed.group,
            sender: seed.sender,
            content: seed.content,
            retainedAliases: seed.retainedAliases,
            hasPartialLegacyProvenance: false
          )
        )
      }
    }

    try checkDeadline(deadline, timeout: timeout)
    if expectedMessageIDs.isEmpty {
      try recordMigration(
        Self.legacyAliasMigrationVersion,
        at: Date().timeIntervalSince1970
      )
    }
    return LegacyAliasScan(
      candidates: candidates,
      expectedMessageIDs: expectedMessageIDs
    )
  }

  private func precanonicalIdentity(
    eventID: String,
    sourceSequence: Int64
  ) -> (recordID: Int64, uuidStorageBytesHex: String)? {
    let parts = eventID.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 6,
      let recordID = Int64(parts[0]),
      recordID == sourceSequence
    else {
      return nil
    }
    let uuidStorageBytesHex = String(parts[1])
    let validHex = uuidStorageBytesHex.unicodeScalars.allSatisfy {
      (48...57).contains($0.value) || (97...102).contains($0.value)
    }
    guard validHex, uuidStorageBytesHex.count % 2 == 0 else { return nil }
    return (recordID, uuidStorageBytesHex)
  }

  private func insertAlias(_ alias: String, messageID: Int64, now: Double) throws {
    guard !(try aliasIsQuarantined(alias)) else {
      throw ListenerError.storage("拒绝重新绑定已隔离的历史兼容 ID")
    }
    if let resolvedMessageID = try self.messageID(matching: [alias]) {
      guard resolvedMessageID == messageID else { return }
      return
    }
    let statement = try prepare(
      """
      INSERT OR IGNORE INTO message_event_aliases(alias_event_id, message_id, created_at)
      VALUES (?, ?, ?)
      """
    )
    defer { sqlite3_finalize(statement) }
    try bindText(alias, to: statement, at: 1)
    try bindInt64(messageID, to: statement, at: 2)
    try bindDouble(now, to: statement, at: 3)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteStorageError(database) }
  }

  private func assertOwnership() throws {
    let statement = try prepare(
      "SELECT 1 FROM listener_state WHERE singleton_id = 1 AND instance_id = ?"
    )
    defer { sqlite3_finalize(statement) }
    try bindText(instanceID, to: statement, at: 1)
    let step = sqlite3_step(statement)
    if step == SQLITE_ROW { return }
    if step == SQLITE_DONE { throw ListenerError.storage("监听实例已被替换") }
    throw sqliteStorageError(database)
  }

  private func beginListenerInstance(groups: [String]) throws {
    let groupData = try JSONSerialization.data(withJSONObject: groups, options: [])
    guard let groupJSON = String(data: groupData, encoding: .utf8) else {
      throw ListenerError.storage("无法编码群名快照")
    }
    let now = Date().timeIntervalSince1970
    let statement = try prepare(
      """
      INSERT INTO listener_state(
        singleton_id, instance_id, group_names_json, started_at, heartbeat_at, updated_at
      ) VALUES (1, ?, ?, ?, ?, ?)
      ON CONFLICT(singleton_id) DO UPDATE SET
        instance_id = excluded.instance_id,
        group_names_json = excluded.group_names_json,
        started_at = excluded.started_at,
        heartbeat_at = excluded.heartbeat_at,
        updated_at = excluded.updated_at
      """
    )
    defer { sqlite3_finalize(statement) }
    try bindText(instanceID, to: statement, at: 1)
    try bindText(groupJSON, to: statement, at: 2)
    try bindDouble(now, to: statement, at: 3)
    try bindDouble(0, to: statement, at: 4)
    try bindDouble(now, to: statement, at: 5)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteStorageError(database) }
  }

  private func updateCheckpoint(timestamp: Double, recordID: Int64, now: Double) throws {
    let statement = try prepare(
      """
      UPDATE listener_state
      SET cursor_timestamp = ?, cursor_record_id = ?, updated_at = ?
      WHERE singleton_id = 1 AND (
        cursor_timestamp IS NULL OR cursor_record_id IS NULL OR
        cursor_timestamp < ? OR (cursor_timestamp = ? AND cursor_record_id < ?)
      )
      """
    )
    defer { sqlite3_finalize(statement) }
    try bindDouble(timestamp, to: statement, at: 1)
    try bindInt64(recordID, to: statement, at: 2)
    try bindDouble(now, to: statement, at: 3)
    try bindDouble(timestamp, to: statement, at: 4)
    try bindDouble(timestamp, to: statement, at: 5)
    try bindInt64(recordID, to: statement, at: 6)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteStorageError(database) }
  }

  private func messageType(for content: String) -> String {
    let mediaMarkers = ["[图片]", "[视频]", "[语音]", "[文件]", "[Photo]", "[Video]", "[File]"]
    return mediaMarkers.contains { content.contains($0) } ? "media" : "text"
  }

  private static var sqliteTransientDestructor: sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  }
}

private func isTransientDatabaseError(_ error: Error) -> Bool {
  if case ListenerError.sqliteStorage(let extendedCode, _) = error {
    let primaryCode = extendedCode & 0xff
    return primaryCode == SQLITE_BUSY || primaryCode == SQLITE_LOCKED
  }
  let value = String(describing: error).lowercased()
  return value.contains("locked") || value.contains("busy")
}

private func isTransientDatabaseMessage(_ message: String) -> Bool {
  let value = message.lowercased()
  return value.contains("locked") || value.contains("busy")
}

private enum DatabaseStatus {
  case usable
  case temporarilyLocked
  case permissionDenied
  case unusable(String)
}

private enum DatabaseCandidatePathStatus {
  case missing
  case present
  case permissionDenied
}

private func databaseCandidatePathStatus(_ path: String) -> DatabaseCandidatePathStatus {
  var information = stat()
  errno = 0
  if lstat(path, &information) == 0 { return .present }
  if errno == EACCES || errno == EPERM { return .permissionDenied }
  return .missing
}

private func isPermissionDatabaseMessage(_ message: String) -> Bool {
  let value = message.lowercased()
  return value.contains("permission denied")
    || value.contains("operation not permitted")
    || value.contains("authorization denied")
    || value.contains("not authorized")
}

private func notificationSourceIsNotReady(_ path: String) -> Bool {
  guard FileManager.default.fileExists(atPath: path) else { return true }
  var database: OpaquePointer?
  let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
  guard result == SQLITE_OK, let openedDatabase = database else {
    if let database = database { sqlite3_close(database) }
    return false
  }
  defer { sqlite3_close(openedDatabase) }
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(
    openedDatabase,
    "SELECT name FROM sqlite_master WHERE type = 'table'",
    -1,
    &statement,
    nil
  ) == SQLITE_OK, let prepared = statement else {
    if let statement = statement { sqlite3_finalize(statement) }
    return false
  }
  defer { sqlite3_finalize(prepared) }
  var tables = Set<String>()
  while true {
    let step = sqlite3_step(prepared)
    if step == SQLITE_DONE { break }
    guard step == SQLITE_ROW else { return false }
    if let text = sqlite3_column_text(prepared, 0) {
      tables.insert(String(cString: text))
    }
  }
  if tables.isEmpty { return true }
  let hasApp = tables.contains("app")
  let hasRecord = tables.contains("record")
  return hasApp != hasRecord
}

private func databaseStatus(_ path: String) -> DatabaseStatus {
  var database: OpaquePointer?
  let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
  guard result == SQLITE_OK, let openedDatabase = database else {
    let message = sqliteMessage(database)
    if let database = database { sqlite3_close(database) }
    if isTransientDatabaseMessage(message) { return .temporarilyLocked }
    if isPermissionDatabaseMessage(message) { return .permissionDenied }
    return .unusable(message)
  }
  defer { sqlite3_close(openedDatabase) }
  sqlite3_busy_timeout(openedDatabase, 250)
  var statement: OpaquePointer?
  let sql = "SELECT 1 FROM app JOIN record ON record.app_id=app.app_id LIMIT 0"
  let prepare = sqlite3_prepare_v2(openedDatabase, sql, -1, &statement, nil)
  if let statement = statement { sqlite3_finalize(statement) }
  if prepare == SQLITE_OK { return .usable }
  let message = sqliteMessage(openedDatabase)
  if isTransientDatabaseMessage(message) { return .temporarilyLocked }
  if isPermissionDatabaseMessage(message) { return .permissionDenied }
  return .unusable(message)
}

private func darwinUserDirectory() -> String? {
  let environment = ProcessInfo.processInfo.environment
  if let value = environment["DARWIN_USER_DIR"], !value.isEmpty { return value }
  let process = Process()
  let executable = environment["WXFOMO_TEST_GETCONF_EXECUTABLE"] ?? "/usr/bin/getconf"
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = ["DARWIN_USER_DIR"]
  let output = Pipe()
  process.standardOutput = output
  process.standardError = Pipe()
  do {
    try process.run()
    process.waitUntilExit()
  } catch {
    return nil
  }
  guard process.terminationStatus == 0 else { return nil }
  let data = output.fileHandleForReading.readDataToEndOfFile()
  let value = String(data: data, encoding: .utf8).map(trimmed) ?? ""
  return value.isEmpty ? nil : value
}

private func databaseDiscoveryCandidates() -> [String] {
  let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
  var candidates = [
    URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
      .path
  ]
  if let directory = darwinUserDirectory() {
    candidates.append(
      URL(fileURLWithPath: directory, isDirectory: true)
        .appendingPathComponent("com.apple.notificationcenter/db2/db")
        .path
    )
  }
  return candidates
}

private func resolveDatabasePath(
  explicitPath: String?,
  discoveryCandidates: [String]
) throws -> String {
  if let explicitPath = explicitPath { return explicitPath }
  var firstUnusable: (path: String, reason: String)?
  var foundPermissionDenied = false
  for candidate in discoveryCandidates {
    switch databaseCandidatePathStatus(candidate) {
    case .missing:
      continue
    case .permissionDenied:
      foundPermissionDenied = true
      continue
    case .present:
      break
    }
    if notificationSourceIsNotReady(candidate) { continue }
    switch databaseStatus(candidate) {
    case .usable, .temporarilyLocked: return candidate
    case .permissionDenied:
      foundPermissionDenied = true
    case .unusable(let reason):
      if firstUnusable == nil { firstUnusable = (candidate, reason) }
    }
  }
  if let unusable = firstUnusable {
    let reason = unusable.reason.isEmpty ? "无法读取或架构不兼容" : unusable.reason
    throw ListenerError.database(
      "Notification Center 数据库已存在但不可用：\(unusable.path)：\(reason)"
    )
  }
  if foundPermissionDenied {
    throw ListenerError.database("Notification Center 数据库路径权限不足")
  }
  throw ListenerError.databaseMissing(
    "未找到可读取的 Notification Center 数据库。请先给终端授予“完全磁盘访问”权限"
  )
}

private func resolveDatabasePathWithRetry(
  options: Options,
  deadline: Date
) throws -> String {
  let discoveryCandidates = options.databasePath == nil ? databaseDiscoveryCandidates() : []
  let discoveryRetryInterval = max(options.pollInterval, 1.0)
  while true {
    do {
      return try resolveDatabasePath(
        explicitPath: options.databasePath,
        discoveryCandidates: discoveryCandidates
      )
    } catch ListenerError.databaseMissing {
      if options.once && Date() >= deadline { throw ListenerError.timedOut(options.timeout) }
      Thread.sleep(forTimeInterval: discoveryRetryInterval)
    }
  }
}

private func notificationSourceKey(_ path: String) throws -> String {
  let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
  var info = stat()
  guard lstat(standardizedPath, &info) == 0, fileType(info) == mode_t(S_IFREG) else {
    let message = errno == 0 ? "通知数据库不是普通文件" : String(cString: strerror(errno))
    throw ListenerError.database(message)
  }
  return "\(standardizedPath)|\(info.st_dev)|\(info.st_ino)"
}

private func hex(_ data: Data) -> String {
  return data.map { String(format: "%02x", $0) }.joined()
}

private func stableHash(_ value: String) -> String {
  var hash: UInt64 = 14_695_981_039_346_656_037
  for byte in value.utf8 {
    hash ^= UInt64(byte)
    hash = hash &* 1_099_511_628_211
  }
  return String(format: "%016llx", hash)
}

private func columnData(_ statement: OpaquePointer, index: Int32) -> Data {
  let count = Int(sqlite3_column_bytes(statement, index))
  guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
  return Data(bytes: bytes, count: count)
}

private func columnStringOrBlob(_ statement: OpaquePointer, index: Int32) -> String? {
  switch sqlite3_column_type(statement, index) {
  case SQLITE_TEXT:
    guard let text = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: text)
  case SQLITE_BLOB:
    let data = columnData(statement, index: index)
    return data.isEmpty ? nil : hex(data)
  default:
    return nil
  }
}

private func payloadHash(_ data: Data) -> String {
  var hash: UInt64 = 14_695_981_039_346_656_037
  for byte in data {
    hash ^= UInt64(byte)
    hash = hash &* 1_099_511_628_211
  }
  return String(format: "%016llx", hash)
}

private func columnDateFingerprint(_ statement: OpaquePointer, index: Int32) -> String {
  if sqlite3_column_type(statement, index) == SQLITE_NULL { return "null" }
  return String(format: "%.17g", sqlite3_column_double(statement, index))
}

private func legacyNativeText(_ value: Any?) -> String {
  let raw: String
  if let value = value as? String {
    raw = value
  } else if let values = value as? [Any] {
    raw = flattenedStrings(values).last ?? ""
  } else {
    raw = ""
  }
  return raw
    .replacingOccurrences(of: "\r", with: " ")
    .replacingOccurrences(of: "\n", with: " ")
    .replacingOccurrences(of: "\t", with: " ")
    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func legacyFileURL(_ value: Any) -> URL? {
  if let url = value as? URL, url.isFileURL { return url.standardizedFileURL }
  guard let raw = value as? String else { return nil }
  let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  if value.hasPrefix("/") { return URL(fileURLWithPath: value).standardizedFileURL }
  guard let url = URL(string: value), url.isFileURL else { return nil }
  return url.standardizedFileURL
}

private func legacyAttachmentURLs(from request: [String: Any]) -> [URL] {
  var results: [URL] = []
  func collect(_ value: Any) {
    if let dictionary = value as? [String: Any] {
      let normalized = Dictionary(uniqueKeysWithValues: dictionary.map {
        ($0.key.lowercased(), $0.value)
      })
      for key in ["url", "fileurl", "path", "filepath", "localurl"] {
        if let candidate = normalized[key], let url = legacyFileURL(candidate) {
          results.append(url)
        }
      }
      for (key, child) in normalized where
        !["url", "fileurl", "path", "filepath", "localurl"].contains(key)
      {
        collect(child)
      }
      return
    }
    if let values = value as? [Any] {
      for child in values { collect(child) }
      return
    }
    if let url = legacyFileURL(value) { results.append(url) }
  }

  for (key, value) in request {
    let normalized = key.lowercased()
    if normalized == "atta" || normalized.contains("attach") { collect(value) }
  }
  var seen = Set<String>()
  return results.filter { seen.insert($0.standardizedFileURL.path).inserted }
}

private func legacyNativeEventID(
  eventSeed: String,
  title: String,
  subtitle: String,
  body: String,
  attachmentSeed: String
) -> String {
  return stableHash(
    "notification|\(eventSeed)|\(legacyNativeText(title))|"
      + "\(legacyNativeText(subtitle))|\(legacyNativeText(body))|"
      + attachmentSeed
  )
}

private let legacyNativeIgnoredNameCharacters = CharacterSet.whitespacesAndNewlines.union(
  CharacterSet(
    charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{2066}\u{2067}\u{2068}\u{2069}\u{FEFF}"
  )
)

private func legacyNativePolicyName(_ value: String) -> String {
  let folded = value.folding(
    options: [.caseInsensitive, .diacriticInsensitive],
    locale: .current
  )
  return String(folded.unicodeScalars.filter {
    !legacyNativeIgnoredNameCharacters.contains($0)
  })
}

private func legacyNativePolicyNonGroupValue(
  _ value: String,
  group: String
) -> String? {
  let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !candidate.isEmpty,
    !legacyNativePolicyName(candidate).contains(legacyNativePolicyName(group))
  else {
    return nil
  }
  return candidate
}

private func legacyNativePolicySenderPrefix(
  _ value: String
) -> (sender: String, content: String)? {
  for separator in ["：", ":"] {
    guard let range = value.range(of: separator) else { continue }
    if separator == ":",
      range.upperBound < value.endIndex,
      !value[range.upperBound].isWhitespace
    {
      continue
    }
    let sender = String(value[..<range.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let content = String(value[range.upperBound...])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !sender.isEmpty, sender.count <= 80, !content.isEmpty {
      return (sender, content)
    }
  }
  return nil
}

private func legacyNativePolicyProjects(
  title: String,
  subtitle: String,
  body: String,
  group: String,
  sender: String,
  content: String
) -> Bool {
  // NotificationPayloadDecoder.clean ran before the historical mapper and
  // policy.  Apply that exact text projection before validating a rebuilt raw
  // layout; the event-ID helper below uses the same normalization.
  let cleanTitle = legacyNativeText(title)
  let cleanSubtitle = legacyNativeText(subtitle)
  let cleanBody = legacyNativeText(body)
  let normalizedGroup = legacyNativePolicyName(group)
  guard !normalizedGroup.isEmpty,
    [cleanTitle, cleanSubtitle].map(legacyNativePolicyName).contains(normalizedGroup)
  else {
    return false
  }
  let groupIsTitle = legacyNativePolicyName(cleanTitle) == normalizedGroup
  let senderField = legacyNativePolicyNonGroupValue(
    groupIsTitle ? cleanSubtitle : cleanTitle,
    group: group
  )
  let prefixed = legacyNativePolicySenderPrefix(cleanBody)
  if let senderField = senderField,
    let prefixed = prefixed,
    legacyNativePolicyName(senderField) != legacyNativePolicyName(prefixed.sender)
  {
    return false
  }
  guard let resolvedSender = senderField ?? prefixed?.sender,
    !resolvedSender.isEmpty
  else {
    return false
  }
  let resolvedContent: String
  if let prefixed = prefixed,
    legacyNativePolicyName(prefixed.sender) == legacyNativePolicyName(resolvedSender)
  {
    resolvedContent = prefixed.content
  } else {
    resolvedContent = cleanBody.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  return !resolvedContent.isEmpty
    && legacyNativeText(resolvedSender) == legacyNativeText(sender)
    && legacyNativeText(resolvedContent) == legacyNativeText(content)
}

private func legacyNativeCompatibilityEventIDs(
  eventSeed: String,
  group: String,
  sender: String,
  content: String
) -> [String] {
  // The pre-canonical standalone store retained the policy result rather than
  // the raw notification fields.  Rebuild the finite, normalized field layouts
  // used by the two production WeCom formats (sender field and body prefix),
  // in both title/subtitle orders.  The old policy accepted every full-width
  // colon layout, but required whitespace after an ASCII colon.  Alias collision
  // preflight remains fail-closed.
  var layouts: [(title: String, subtitle: String, body: String)] = [
    (title: group, subtitle: sender, body: content),
    (title: sender, subtitle: group, body: content),
  ]
  let prefixedBodies = [
    "\(sender)：\(content)",
    "\(sender)： \(content)",
    "\(sender) ：\(content)",
    "\(sender) ： \(content)",
    "\(sender): \(content)",
    "\(sender) : \(content)",
  ]
  for prefixedBody in prefixedBodies {
    layouts.append((title: group, subtitle: "", body: prefixedBody))
    layouts.append((title: "", subtitle: group, body: prefixedBody))
    layouts.append((title: group, subtitle: sender, body: prefixedBody))
    layouts.append((title: sender, subtitle: group, body: prefixedBody))
    layouts.append((title: group, subtitle: group, body: prefixedBody))
  }
  var seen = Set<String>()
  return layouts.filter {
    legacyNativePolicyProjects(
      title: $0.title,
      subtitle: $0.subtitle,
      body: $0.body,
      group: group,
      sender: sender,
      content: content
    )
  }.map {
    legacyNativeEventID(
      eventSeed: eventSeed,
      title: $0.title,
      subtitle: $0.subtitle,
      body: $0.body,
      attachmentSeed: ""
    )
  }.filter { seen.insert($0).inserted }
}

private func legacyNativeVersion1WitnessEventIDs(
  eventSeed: String,
  group: String,
  sender: String,
  content: String
) -> [String] {
  // Marker 301 producers from baa877b and later materialized exactly these
  // twelve IDs for every semantic revision.  Their presence and individual
  // creation times no later than marker 301 are the recoverable per-row witness
  // for a single-fingerprint store; later producers can materialize the same
  // IDs and therefore remain fail-closed without that time boundary.
  var layouts: [(title: String, subtitle: String, body: String)] = [
    (title: group, subtitle: sender, body: content),
    (title: sender, subtitle: group, body: content),
  ]
  for prefixedBody in ["\(sender)：\(content)", "\(sender): \(content)"] {
    layouts.append((title: group, subtitle: "", body: prefixedBody))
    layouts.append((title: "", subtitle: group, body: prefixedBody))
    layouts.append((title: group, subtitle: sender, body: prefixedBody))
    layouts.append((title: sender, subtitle: group, body: prefixedBody))
    layouts.append((title: group, subtitle: group, body: prefixedBody))
  }
  var seen = Set<String>()
  return layouts.map {
    legacyNativeEventID(
      eventSeed: eventSeed,
      title: $0.title,
      subtitle: $0.subtitle,
      body: $0.body,
      attachmentSeed: ""
    )
  }.filter { seen.insert($0).inserted }
}

private func plannedLegacyPrefixAliasIDs(
  notification: StoredNotification,
  candidate: MessageDatabase.LegacyPrefixAliasCandidate,
  currentMessage: GroupMessage?
) -> [String]? {
  guard candidate.recordID == notification.recordID,
    candidate.uuidStorageBytesHex == notification.uuidStorageBytesHex,
    let eventSeed = notification.stableUUID,
    !eventSeed.isEmpty,
    notification.eventID == stableHash("notification|\(eventSeed)"),
    candidate.canonicalEventID == notification.eventID
  else {
    return nil
  }
  if candidate.requiresVersion1SemanticWitness {
    guard let version1AppliedAt = candidate.version1AppliedAt,
      version1AppliedAt.isFinite
    else {
      return nil
    }
    let witnesses = legacyNativeVersion1WitnessEventIDs(
      eventSeed: eventSeed,
      group: candidate.group,
      sender: candidate.sender,
      content: candidate.content
    )
    let witnessSet = Set(witnesses)
    guard witnesses.allSatisfy({ witness in
      guard let createdAt = candidate.retainedEventCreatedAt[witness] else {
        return false
      }
      return createdAt.isFinite && createdAt <= version1AppliedAt
    }) else {
      return nil
    }
    // Wall-clock ordering alone is not proof across a system-clock rollback.
    // baa877b's version-1 transaction wrote the twelve witnesses plus at most
    // one raw native layout.  Earlier marker-301 producers wrote only that raw
    // layout plus the direct-normal ID, while the later round-5 scanner wrote
    // the entire policy-valid compatibility set before recording 302 in a
    // separate transaction.  Reject that combined producer signature even if
    // every later timestamp was moved before marker 301.  If round 5 plus the
    // one direct-normal ID still cannot cover the witness set, the missing IDs
    // distinguish the producers and the finite timestamp proof remains usable.
    let round5CompatibilityIDs = Set(legacyNativeCompatibilityEventIDs(
      eventSeed: eventSeed,
      group: candidate.group,
      sender: candidate.sender,
      content: candidate.content
    ))
    let earlyDirectNormalID = legacyNativeEventID(
      eventSeed: eventSeed,
      title: candidate.group,
      subtitle: candidate.sender,
      body: candidate.content,
      attachmentSeed: ""
    )
    let unsafeCombinedProducerIDs = round5CompatibilityIDs.union([
      earlyDirectNormalID
    ])
    if witnessSet.isSubset(of: unsafeCombinedProducerIDs) {
      let expandedCompatibilityIDs = round5CompatibilityIDs.subtracting(witnessSet)
      let retainedExpandedBeforeVersion1 = expandedCompatibilityIDs.filter { alias in
        guard let createdAt = candidate.retainedEventCreatedAt[alias] else {
          return false
        }
        return createdAt.isFinite && createdAt <= version1AppliedAt
      }
      guard expandedCompatibilityIDs.count > 1,
        retainedExpandedBeforeVersion1.count <= 1
      else {
        return nil
      }
    }
  }
  var aliases = legacyNativeCompatibilityEventIDs(
    eventSeed: eventSeed,
    group: candidate.group,
    sender: candidate.sender,
    content: candidate.content
  )
  if let currentMessage = currentMessage {
    aliases.append(contentsOf: legacyNativeCompatibilityEventIDs(
      eventSeed: eventSeed,
      group: currentMessage.group,
      sender: currentMessage.sender,
      content: currentMessage.content
    ))
  }
  var seen = Set<String>()
  return aliases.filter { !$0.isEmpty && seen.insert($0).inserted }
}

private func legacyNativeEventID(
  recordID: Int64,
  uuid: String?,
  payload: Data
) -> String? {
  guard let root = try? PropertyListSerialization.propertyList(
    from: payload,
    options: [],
    format: nil
  ) as? [String: Any],
    let request = root["req"] as? [String: Any]
  else {
    return nil
  }
  let eventSeed = uuid ?? String(recordID)
  let attachmentSeed = legacyAttachmentURLs(from: request)
    .map(\.absoluteString)
    .joined(separator: "|")
  return legacyNativeEventID(
    eventSeed: eventSeed,
    title: legacyNativeText(request["titl"]),
    subtitle: legacyNativeText(request["subt"]),
    body: legacyNativeText(request["body"]),
    attachmentSeed: attachmentSeed
  )
}

private func fetchNotifications(
  databasePath: String,
  sourceIdentity: String,
  fetch: NotificationFetch
) throws -> [StoredNotification] {
  guard try notificationSourceKey(databasePath) == sourceIdentity else {
    throw ListenerError.notificationSourceChanged("通知数据库在读取前已更改")
  }
  var database: OpaquePointer?
  let openResult = sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY, nil)
  guard openResult == SQLITE_OK, let openedDatabase = database else {
    let message = sqliteMessage(database)
    if let database = database { sqlite3_close(database) }
    throw ListenerError.database(message)
  }
  defer { sqlite3_close(openedDatabase) }
  sqlite3_busy_timeout(openedDatabase, 250)

  let sourceFilter = """
    lower(trim(a.identifier)) IN (
      'com.tencent.weworkmac',
      '88l2q4487u.com.tencent.weworkmac'
    )
    """
  let updateExpression = "COALESCE(r.request_last_date, r.delivered_date, r.request_date, 0)"
  let sql: String
  switch fetch {
  case .latest:
    sql = """
      SELECT rec_id, uuid, data, request_date, request_last_date, delivered_date,
        update_timestamp
      FROM (
        SELECT r.rec_id AS rec_id, r.uuid AS uuid, r.data AS data,
          r.request_date AS request_date, r.request_last_date AS request_last_date,
          r.delivered_date AS delivered_date, \(updateExpression) AS update_timestamp
        FROM record r
        JOIN app a ON a.app_id = r.app_id
        WHERE \(sourceFilter)
        ORDER BY update_timestamp DESC, r.rec_id DESC
        LIMIT ?
      )
      ORDER BY update_timestamp ASC, rec_id ASC
      """
  case .since:
    sql = """
      SELECT r.rec_id, r.uuid, r.data, r.request_date, r.request_last_date,
        r.delivered_date, \(updateExpression) AS update_timestamp
      FROM record r
      JOIN app a ON a.app_id = r.app_id
      WHERE \(sourceFilter) AND (
        \(updateExpression) > ? OR (\(updateExpression) = ? AND r.rec_id > ?)
      )
      ORDER BY update_timestamp ASC, r.rec_id ASC
      LIMIT ?
      """
  case .recordIDs(let recordIDs):
    guard !recordIDs.isEmpty else { return [] }
    let placeholders = recordIDs.map { _ in "?" }.joined(separator: ",")
    sql = """
      SELECT r.rec_id, r.uuid, r.data, r.request_date, r.request_last_date,
        r.delivered_date, \(updateExpression) AS update_timestamp
      FROM record r
      JOIN app a ON a.app_id = r.app_id
      WHERE \(sourceFilter) AND r.rec_id IN (\(placeholders))
      ORDER BY update_timestamp ASC, r.rec_id ASC
      """
  }
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(openedDatabase, sql, -1, &statement, nil) == SQLITE_OK,
    let preparedStatement = statement
  else {
    throw ListenerError.database(sqliteMessage(openedDatabase))
  }
  defer { sqlite3_finalize(preparedStatement) }
  switch fetch {
  case .latest(let limit):
    sqlite3_bind_int(preparedStatement, 1, Int32(limit))
  case .since(let timestamp, let recordID, let limit):
    sqlite3_bind_double(preparedStatement, 1, timestamp)
    sqlite3_bind_double(preparedStatement, 2, timestamp)
    sqlite3_bind_int64(preparedStatement, 3, recordID)
    sqlite3_bind_int(preparedStatement, 4, Int32(limit))
  case .recordIDs(let recordIDs):
    for (index, recordID) in recordIDs.enumerated() {
      sqlite3_bind_int64(preparedStatement, Int32(index + 1), recordID)
    }
  }

  var records: [StoredNotification] = []
  while true {
    let step = sqlite3_step(preparedStatement)
    if step == SQLITE_DONE { break }
    guard step == SQLITE_ROW else {
      throw ListenerError.database(sqliteMessage(openedDatabase))
    }
    let recordID = sqlite3_column_int64(preparedStatement, 0)
    let uuidData = columnData(preparedStatement, index: 1)
    let payload = columnData(preparedStatement, index: 2)
    let deliveredSeconds = sqlite3_column_type(preparedStatement, 5) == SQLITE_NULL
      ? 0
      : sqlite3_column_double(preparedStatement, 5)
    let updateTimestamp = sqlite3_column_double(preparedStatement, 6)
    let uuid = columnStringOrBlob(preparedStatement, index: 1)
    let eventID: String
    if let uuid = uuid, !uuid.isEmpty {
      eventID = stableHash("notification|\(uuid)")
    } else {
      eventID = stableHash(
        "notification|source:\(sourceIdentity)|row:\(recordID)"
      )
    }
    let legacyLANEventID = [
      String(recordID), hex(uuidData),
      columnDateFingerprint(preparedStatement, index: 3),
      columnDateFingerprint(preparedStatement, index: 4),
      columnDateFingerprint(preparedStatement, index: 5),
      payloadHash(payload),
    ].joined(separator: ":")
    records.append(
      StoredNotification(
        recordID: recordID,
        eventID: eventID,
        stableUUID: uuid,
        uuidStorageBytesHex: hex(uuidData),
        hasStableUUID: uuid.map { !$0.isEmpty } ?? false,
        legacyLANEventID: legacyLANEventID,
        legacyNativeEventID: legacyNativeEventID(
          recordID: recordID,
          uuid: uuid,
          payload: payload
        ),
        updateTimestamp: updateTimestamp,
        deliveredAt: Date(timeIntervalSinceReferenceDate: deliveredSeconds),
        payload: payload
      )
    )
  }
  guard try notificationSourceKey(databasePath) == sourceIdentity else {
    throw ListenerError.notificationSourceChanged("通知数据库在读取期间已更改")
  }
  return records
}

private func flattenedStrings(_ value: Any) -> [String] {
  if let string = value as? String { return [string] }
  if let values = value as? [Any] { return values.flatMap(flattenedStrings) }
  if let dictionary = value as? [String: Any] {
    return dictionary.keys.sorted().flatMap { key in
      return dictionary[key].map(flattenedStrings) ?? []
    }
  }
  return []
}

private func extractedText(_ value: Any?) -> String {
  guard let value = value else { return "" }
  return flattenedStrings(value).last ?? ""
}

private func normalizedName(_ value: String) -> String {
  return canonicalGroupName(value)
}

private func nonGroupValue(_ value: String, group: String) -> String? {
  let candidate = trimmed(value)
  guard !candidate.isEmpty,
    normalizedName(candidate) != normalizedName(group)
  else {
    return nil
  }
  return candidate
}

private func splitSenderPrefix(_ value: String) -> (sender: String, content: String)? {
  for separator in ["：", ":"] {
    guard let range = value.range(of: separator) else { continue }
    if separator == ":",
      range.upperBound < value.endIndex,
      !value[range.upperBound].isWhitespace
    {
      continue
    }
    let sender = trimmed(String(value[..<range.lowerBound]))
    let content = trimmed(String(value[range.upperBound...]))
    if !sender.isEmpty, sender.count <= 80, !content.isEmpty {
      return (sender, content)
    }
  }
  return nil
}

private func groupMessage(
  title: String,
  subtitle: String,
  body: String,
  conversationType: Int,
  groups: [String]
) -> GroupMessage? {
  guard conversationType == 1 else { return nil }
  let values = Set([title, subtitle].map(normalizedName).filter { !$0.isEmpty })
  let candidates = groups.map { (original: $0, normalized: normalizedName($0)) }
    .filter { !$0.normalized.isEmpty && values.contains($0.normalized) }
  let originalNames = Set(candidates.map { $0.original })
  let normalizedNames = Set(candidates.map { $0.normalized })
  guard originalNames.count == 1, normalizedNames.count == 1,
    let group = candidates.first?.original
  else {
    return nil
  }

  let groupIsTitle = normalizedName(title) == normalizedName(group)
  let senderField = groupIsTitle
    ? nonGroupValue(subtitle, group: group)
    : nonGroupValue(title, group: group)
  let prefixed = splitSenderPrefix(body)
  if let senderField = senderField,
    let prefixed = prefixed,
    normalizedName(senderField) != normalizedName(prefixed.sender)
  {
    return nil
  }
  guard let sender = senderField ?? prefixed?.sender, !sender.isEmpty else { return nil }
  let content: String
  if let prefixed = prefixed,
    normalizedName(prefixed.sender) == normalizedName(sender)
  {
    content = prefixed.content
  } else {
    content = trimmed(body)
  }
  guard !content.isEmpty else { return nil }
  return GroupMessage(group: group, sender: sender, content: content)
}

private func conversationType(from request: [String: Any]) -> Int? {
  guard let archive = request["usda"] as? Data,
    let decoded = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(archive),
    let userData = decoded as? [String: Any],
    let value = userData["ct"] as? NSNumber
  else {
    return nil
  }
  return value.intValue
}

private func decodeMessage(_ notification: StoredNotification, groups: [String]) -> GroupMessage? {
  guard
    let root = try? PropertyListSerialization.propertyList(
      from: notification.payload,
      options: [],
      format: nil
    ) as? [String: Any],
    let request = root["req"] as? [String: Any]
  else {
    return nil
  }
  guard let type = conversationType(from: request) else { return nil }
  return groupMessage(
    title: extractedText(request["titl"]),
    subtitle: extractedText(request["subt"]),
    body: extractedText(request["body"]),
    conversationType: type,
    groups: groups
  )
}

private func output(_ message: GroupMessage, deliveredAt: Date) {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "zh_CN")
  formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
  print("[\(formatter.string(from: deliveredAt))] [\(message.group)] \(message.sender)：\(message.content)")
  fflush(stdout)
}

private func waitIfDatabaseIsTransient(_ error: Error, interval: TimeInterval) -> Bool {
  guard isTransientDatabaseError(error) else { return false }
  Thread.sleep(forTimeInterval: interval)
  return true
}

private func waitIfNotificationSourceIsNotReady(
  _ path: String,
  interval: TimeInterval
) -> Bool {
  guard notificationSourceIsNotReady(path) else { return false }
  Thread.sleep(forTimeInterval: interval)
  return true
}

private func messageDatabaseWithRetry(
  path: String,
  groups: [String],
  instanceID: String,
  options: Options,
  deadline: Date
) throws -> MessageDatabase {
  while true {
    do {
      return try MessageDatabase(path: path, groups: groups, instanceID: instanceID)
    } catch {
      if options.once && Date() >= deadline { throw ListenerError.timedOut(options.timeout) }
      guard waitIfDatabaseIsTransient(error, interval: options.pollInterval) else { throw error }
    }
  }
}

private func notificationSourceKeyWithRetry(
  databasePath: String,
  options: Options,
  deadline: Date
) throws -> String {
  while true {
    do {
      return try validatedNotificationSourceKey(databasePath)
    } catch {
      if options.once && Date() >= deadline { throw ListenerError.timedOut(options.timeout) }
      if waitIfNotificationSourceIsNotReady(databasePath, interval: options.pollInterval) {
        continue
      }
      if case ListenerError.notificationSourceChanged = error {
        Thread.sleep(forTimeInterval: options.pollInterval)
        continue
      }
      guard waitIfDatabaseIsTransient(error, interval: options.pollInterval) else { throw error }
    }
  }
}

private func validatedNotificationSourceKey(_ databasePath: String) throws -> String {
  let sourceKey = try notificationSourceKey(databasePath)
  _ = try fetchNotifications(
    databasePath: databasePath,
    sourceIdentity: sourceKey,
    fetch: .latest(1)
  )
  stopBeforeSourceValidationConfirmationForTestIfRequested()
  guard try notificationSourceKey(databasePath) == sourceKey else {
    throw ListenerError.notificationSourceChanged("通知数据库在验证期间已更改")
  }
  return sourceKey
}

private func bindSourceWithRetry(
  database: MessageDatabase,
  sourceKey: String,
  options: Options,
  deadline: Date
) throws -> MessageDatabase.SourceBinding {
  while true {
    do {
      return try database.bindSource(
        sourceKey,
        deadline: options.once ? deadline : nil,
        timeout: options.timeout
      )
    } catch {
      if options.once && Date() >= deadline { throw ListenerError.timedOut(options.timeout) }
      guard waitIfDatabaseIsTransient(error, interval: options.pollInterval) else { throw error }
    }
  }
}

private func consolidateLegacyRevisionPlansWithRetry(
  database: MessageDatabase,
  plans: [MessageDatabase.LegacyAliasConsolidationPlan],
  expectedMessageIDs: Set<Int64>,
  options: Options,
  deadline: Date
) throws -> Set<Int64> {
  while true {
    do {
      return try database.consolidateLegacyRevisionPlans(
        plans,
        expectedMessageIDs: expectedMessageIDs,
        deadline: options.once ? deadline : nil,
        timeout: options.timeout
      )
    } catch {
      if options.once && Date() >= deadline { throw ListenerError.timedOut(options.timeout) }
      guard waitIfDatabaseIsTransient(error, interval: options.pollInterval) else { throw error }
    }
  }
}

private func legacyPrefixAliasScanWithRetry(
  database: MessageDatabase,
  options: Options,
  deadline: Date
) throws -> MessageDatabase.LegacyPrefixAliasScan? {
  while true {
    do {
      return try database.legacyPrefixAliasScanIfNeeded()
    } catch {
      if options.once && Date() >= deadline { throw ListenerError.timedOut(options.timeout) }
      guard waitIfDatabaseIsTransient(error, interval: options.pollInterval) else { throw error }
    }
  }
}

private func addLegacyPrefixAliasesWithRetry(
  database: MessageDatabase,
  notification: StoredNotification,
  candidate: MessageDatabase.LegacyPrefixAliasCandidate,
  aliases: [String],
  options: Options,
  deadline: Date
) throws -> Bool {
  while true {
    do {
      return try database.addLegacyPrefixAliases(
        notification,
        candidate: candidate,
        aliases: aliases
      )
    } catch {
      if options.once && Date() >= deadline { throw ListenerError.timedOut(options.timeout) }
      guard waitIfDatabaseIsTransient(error, interval: options.pollInterval) else { throw error }
    }
  }
}

private func completeLegacyPrefixAliasMigrationWithRetry(
  database: MessageDatabase,
  options: Options,
  deadline: Date
) throws {
  while true {
    do {
      try database.completeLegacyPrefixAliasMigration()
      return
    } catch {
      if options.once && Date() >= deadline { throw ListenerError.timedOut(options.timeout) }
      guard waitIfDatabaseIsTransient(error, interval: options.pollInterval) else { throw error }
    }
  }
}

private func cursorWithRetry(
  database: MessageDatabase,
  options: Options,
  deadline: Date
) throws -> NotificationCursor? {
  while true {
    do {
      return try database.cursor()
    } catch {
      if options.once && Date() >= deadline { throw ListenerError.timedOut(options.timeout) }
      guard waitIfDatabaseIsTransient(error, interval: options.pollInterval) else { throw error }
    }
  }
}

private func persistWithRetry(
  database: MessageDatabase,
  notification: StoredNotification,
  message: GroupMessage?,
  options: Options,
  deadline: Date
) throws -> Bool {
  while true {
    do {
      return try database.persist(notification: notification, message: message)
    } catch {
      if options.once && Date() >= deadline { throw ListenerError.timedOut(options.timeout) }
      guard waitIfDatabaseIsTransient(error, interval: options.pollInterval) else { throw error }
    }
  }
}

private func saveBaselineWithRetry(
  database: MessageDatabase,
  cursor: NotificationCursor,
  options: Options,
  deadline: Date
) throws {
  while true {
    do {
      try database.saveBaseline(cursor)
      return
    } catch {
      if options.once && Date() >= deadline { throw ListenerError.timedOut(options.timeout) }
      guard waitIfDatabaseIsTransient(error, interval: options.pollInterval) else { throw error }
    }
  }
}

private func markReadyWithRetry(
  database: MessageDatabase,
  options: Options,
  deadline: Date
) throws {
  while true {
    do {
      try database.markReady()
      return
    } catch {
      if options.once && Date() >= deadline { throw ListenerError.timedOut(options.timeout) }
      guard waitIfDatabaseIsTransient(error, interval: options.pollInterval) else { throw error }
    }
  }
}

private func markSourceUnavailableWithRetry(
  database: MessageDatabase,
  options: Options,
  deadline: Date
) throws {
  while true {
    do {
      try database.markSourceUnavailable(at: Date().timeIntervalSince1970)
      return
    } catch {
      if options.once && Date() >= deadline { throw ListenerError.timedOut(options.timeout) }
      guard waitIfDatabaseIsTransient(error, interval: options.pollInterval) else { throw error }
    }
  }
}

runPrefixAliasPreflightSelfTestIfRequested()

do {
  let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
  if options.savesGroups {
    try saveGroups(options.commandLineGroups, to: options.configPath)
  }
  let groups = options.commandLineGroups.isEmpty
    ? try loadGroups(from: options.configPath)
    : options.commandLineGroups
  guard !groups.isEmpty else { throw ListenerError.noGroups(options.configPath) }
  let deadline = Date().addingTimeInterval(options.timeout)
  let databasePath = try resolveDatabasePathWithRetry(options: options, deadline: deadline)
  let instanceID = options.instanceID ?? UUID().uuidString.lowercased()
  let messageDatabase = try messageDatabaseWithRetry(
    path: options.storePath,
    groups: groups,
    instanceID: instanceID,
    options: options,
    deadline: deadline
  )
  var sourceKey = try notificationSourceKeyWithRetry(
    databasePath: databasePath,
    options: options,
    deadline: deadline
  )
  let batchSize = 500
  var cursor = NotificationCursor(timestamp: 0, recordID: Int64.min)

  startup: while true {
    let sourceBinding = try bindSourceWithRetry(
      database: messageDatabase,
      sourceKey: sourceKey,
      options: options,
      deadline: deadline
    )
    stopAfterStartupBindingForTestIfRequested()
    let requiresSafetyReplay = sourceBinding.requiresSafetyReplay

    // Resolve only source-verified compatibility aliases before replaying current rows.
    // This prevents a changed legacy row from being inserted again without guessing whether
    // its pre-canonical UUID bytes came from SQLite TEXT or BLOB storage.
    if sourceBinding.legacyAliasMigrationPending {
      let expectedMessageIDs = sourceBinding.legacyAliasExpectedMessageIDs
      var completedMessageIDs = Set<Int64>()
      let candidatesBySource = Dictionary(grouping: sourceBinding.legacyAliasCandidates) {
        "\($0.recordID):\($0.uuidStorageBytesHex)"
      }
      var plans: [MessageDatabase.LegacyAliasConsolidationPlan] = []
      let recordIDs = Array(
        Set(sourceBinding.legacyAliasCandidates.map(\.recordID))
      ).sorted()
      var offset = 0
      while offset < recordIDs.count {
        if options.once && Date() >= deadline {
          throw ListenerError.timedOut(options.timeout)
        }
        let end = min(offset + 400, recordIDs.count)
        let recordIDChunk = Array(recordIDs[offset..<end])
        var notifications: [StoredNotification] = []
        while true {
          do {
            notifications = try fetchNotifications(
              databasePath: databasePath,
              sourceIdentity: sourceKey,
              fetch: .recordIDs(recordIDChunk)
            )
            break
          } catch {
            if options.once && Date() >= deadline {
              throw ListenerError.timedOut(options.timeout)
            }
            if waitIfNotificationSourceIsNotReady(
              databasePath,
              interval: options.pollInterval
            ) {
              continue
            }
            if let currentIdentity = try? notificationSourceKey(databasePath),
              currentIdentity != sourceKey
            {
              sourceKey = try notificationSourceKeyWithRetry(
                databasePath: databasePath,
                options: options,
                deadline: deadline
              )
              continue startup
            }
            guard waitIfDatabaseIsTransient(error, interval: options.pollInterval) else {
              throw error
            }
          }
        }
        let notificationsByRecordID = Dictionary(
          uniqueKeysWithValues: notifications.map { ($0.recordID, $0) }
        )
        for recordID in recordIDChunk {
          if options.once && Date() >= deadline {
            throw ListenerError.timedOut(options.timeout)
          }
          guard let notification = notificationsByRecordID[recordID] else { continue }
          let sourceCandidateKey = "\(recordID):\(notification.uuidStorageBytesHex)"
          let candidates = candidatesBySource[sourceCandidateKey] ?? []
          let message: GroupMessage?
          if let configuredMessage = decodeMessage(notification, groups: groups) {
            message = configuredMessage
          } else {
            // A configured watch list can legitimately drop a historical
            // group after the row was stored.  Candidate group names are
            // source-bound migration evidence, not new runtime subscriptions;
            // decode them together so the existing exact/multi-match guard
            // remains fail-closed.
            let historicalGroups = Array(Set(candidates.map(\.group))).sorted()
            message = decodeMessage(notification, groups: historicalGroups)
          }
          guard let verifiedMessage = message else { continue }
          if let plan = try messageDatabase.planLegacyAliasConsolidation(
            notification,
            message: verifiedMessage,
            candidates: candidates,
            deadline: options.once ? deadline : nil,
            timeout: options.timeout
          ) {
            plans.append(plan)
          }
        }
        offset = end
      }

      let plannedMessageIDs = plans.reduce(into: Set<Int64>()) {
        $0.formUnion($1.candidateIDs)
      }
      if plannedMessageIDs == expectedMessageIDs {
        if options.once && Date() >= deadline {
          throw ListenerError.timedOut(options.timeout)
        }
        completedMessageIDs = try consolidateLegacyRevisionPlansWithRetry(
          database: messageDatabase,
          plans: plans,
          expectedMessageIDs: expectedMessageIDs,
          options: options,
          deadline: deadline
        )
      }
      if completedMessageIDs != expectedMessageIDs {
        let missingCount = expectedMessageIDs.subtracting(completedMessageIDs).count
        fputs(
          "警告：\(missingCount) 条历史通知无法在当前 Notification Center 数据源验证，兼容 ID 迁移保持待完成\n",
          stderr
        )
      }
    }

    // Version 1 may already be recorded in stores produced by an intermediate
    // build.  Re-scan the retained standalone aliases after consolidation so
    // those canonical survivors can receive every policy-valid native prefix
    // alias without rerunning or weakening the original migration marker.
    if let prefixScan = try legacyPrefixAliasScanWithRetry(
      database: messageDatabase,
      options: options,
      deadline: deadline
    ) {
      let expectedMessageIDs = Set(prefixScan.candidates.map(\.messageID))
      var completedMessageIDs = Set<Int64>()
      let candidatesBySource = Dictionary(grouping: prefixScan.candidates) {
        "\($0.recordID):\($0.uuidStorageBytesHex)"
      }
      var aliasPlans: [(
        notification: StoredNotification,
        candidate: MessageDatabase.LegacyPrefixAliasCandidate,
        aliases: [String]
      )] = []
      var prefixMigrationWork = 0
      let recordIDs = Array(Set(prefixScan.candidates.map(\.recordID))).sorted()
      var offset = 0
      while offset < recordIDs.count {
        if options.once && Date() >= deadline {
          throw ListenerError.timedOut(options.timeout)
        }
        let end = min(offset + 400, recordIDs.count)
        let recordIDChunk = Array(recordIDs[offset..<end])
        var notifications: [StoredNotification] = []
        while true {
          do {
            notifications = try fetchNotifications(
              databasePath: databasePath,
              sourceIdentity: sourceKey,
              fetch: .recordIDs(recordIDChunk)
            )
            break
          } catch {
            if options.once && Date() >= deadline {
              throw ListenerError.timedOut(options.timeout)
            }
            if waitIfNotificationSourceIsNotReady(
              databasePath,
              interval: options.pollInterval
            ) {
              continue
            }
            if let currentIdentity = try? notificationSourceKey(databasePath),
              currentIdentity != sourceKey
            {
              sourceKey = try notificationSourceKeyWithRetry(
                databasePath: databasePath,
                options: options,
                deadline: deadline
              )
              continue startup
            }
            guard waitIfDatabaseIsTransient(error, interval: options.pollInterval) else {
              throw error
            }
          }
        }
        let notificationsByRecordID = Dictionary(
          uniqueKeysWithValues: notifications.map { ($0.recordID, $0) }
        )
        for recordID in recordIDChunk {
          guard let notification = notificationsByRecordID[recordID] else { continue }
          let candidateSourceKey = "\(recordID):\(notification.uuidStorageBytesHex)"
          prefixMigrationWork += 1
          let candidates = candidatesBySource[candidateSourceKey] ?? []
          for candidate in candidates {
            prefixMigrationWork += 1
            if options.once && Date() >= deadline {
              throw ListenerError.timedOut(options.timeout)
            }
            // The configured group list may have changed since version 1.
            // Project the current revision against the source-verified
            // historical group; failure only suppresses current aliases and
            // never blocks recovery of the retained historical aliases.
            let message = decodeMessage(notification, groups: [candidate.group])
            if let aliases = plannedLegacyPrefixAliasIDs(
              notification: notification,
              candidate: candidate,
              currentMessage: message
            ) {
              aliasPlans.append((
                notification: notification,
                candidate: candidate,
                aliases: aliases.filter {
                  !prefixScan.quarantinedEventIDs.contains($0)
                }
              ))
            }
          }
        }
        offset = end
      }
      if ProcessInfo.processInfo.environment[
        "WXFOMO_TEST_REPORT_PREFIX_MIGRATION_WORK"
      ] == "1" {
        fputs("旧原生前缀迁移工作量：\(prefixMigrationWork)\n", stderr)
      }

      // Source verification must finish before the first write.  Preflight
      // every recovered alias across candidates so an alias that belongs to
      // two historical owners leaves both rows untouched and the marker
      // pending.  Independent plans remain idempotent and may make recoverable
      // progress when a different plan conflicts with an existing exact row.
      let plannedOwnerIDs = Set(aliasPlans.map { $0.candidate.messageID })
      if plannedOwnerIDs == expectedMessageIDs,
        prefixScan.unresolvedMessageIDs.isEmpty
      {
        let ambiguousOwnerIDs = ambiguousLegacyAliasOwnerIDs(
          aliasPlans.map { (ownerID: $0.candidate.messageID, aliases: $0.aliases) }
        )
        for plan in aliasPlans where !ambiguousOwnerIDs.contains(plan.candidate.messageID) {
          if options.once && Date() >= deadline {
            throw ListenerError.timedOut(options.timeout)
          }
          if try addLegacyPrefixAliasesWithRetry(
            database: messageDatabase,
            notification: plan.notification,
            candidate: plan.candidate,
            aliases: plan.aliases,
            options: options,
            deadline: deadline
          ) {
            completedMessageIDs.insert(plan.candidate.messageID)
          }
        }
      }
      if completedMessageIDs == expectedMessageIDs
        && prefixScan.unresolvedMessageIDs.isEmpty
      {
        try completeLegacyPrefixAliasMigrationWithRetry(
          database: messageDatabase,
          options: options,
          deadline: deadline
        )
      } else {
        let missingCount = expectedMessageIDs.subtracting(completedMessageIDs).count
          + prefixScan.unresolvedMessageIDs.count
        fputs(
          "警告：\(missingCount) 条历史通知无法完成旧原生前缀 ID 升级，迁移保持待完成\n",
          stderr
        )
      }
    }

    if let storedCursor = try cursorWithRetry(
      database: messageDatabase,
      options: options,
      deadline: deadline
    ) {
      cursor = storedCursor
      if options.includesExisting || requiresSafetyReplay {
        var historical: [StoredNotification] = []
        while true {
          do {
            historical = try fetchNotifications(
              databasePath: databasePath,
              sourceIdentity: sourceKey,
              fetch: .latest(batchSize)
            )
            break
          } catch {
            if options.once && Date() >= deadline {
              throw ListenerError.timedOut(options.timeout)
            }
            if waitIfNotificationSourceIsNotReady(
              databasePath,
              interval: options.pollInterval
            ) {
              continue
            }
            if let currentIdentity = try? notificationSourceKey(databasePath),
              currentIdentity != sourceKey
            {
              sourceKey = try notificationSourceKeyWithRetry(
                databasePath: databasePath,
                options: options,
                deadline: deadline
              )
              continue startup
            }
            guard waitIfDatabaseIsTransient(error, interval: options.pollInterval) else {
              throw error
            }
          }
        }
        for notification in historical {
          let message = decodeMessage(notification, groups: groups)
          let inserted = try persistWithRetry(
            database: messageDatabase,
            notification: notification,
            message: message,
            options: options,
            deadline: deadline
          )
          if cursor.accepts(notification) { cursor.advance(to: notification) }
          if inserted, let message = message {
            if options.once {
              try markReadyWithRetry(
                database: messageDatabase,
                options: options,
                deadline: deadline
              )
            }
            output(message, deliveredAt: notification.deliveredAt)
            if options.once { exit(0) }
          }
        }
      }
    } else {
      var initial: [StoredNotification] = []
      while true {
        do {
          initial = try fetchNotifications(
            databasePath: databasePath,
            sourceIdentity: sourceKey,
            fetch: .latest(batchSize)
          )
          break
        } catch {
          if options.once && Date() >= deadline {
            throw ListenerError.timedOut(options.timeout)
          }
          if waitIfNotificationSourceIsNotReady(
            databasePath,
            interval: options.pollInterval
          ) {
            continue
          }
          if let currentIdentity = try? notificationSourceKey(databasePath),
            currentIdentity != sourceKey
          {
            sourceKey = try notificationSourceKeyWithRetry(
              databasePath: databasePath,
              options: options,
              deadline: deadline
            )
            continue startup
          }
          guard waitIfDatabaseIsTransient(error, interval: options.pollInterval) else {
            throw error
          }
        }
      }
      if options.includesExisting || requiresSafetyReplay {
        cursor = NotificationCursor(timestamp: 0, recordID: Int64.min)
        for notification in initial where cursor.accepts(notification) {
          let message = decodeMessage(notification, groups: groups)
          let inserted = try persistWithRetry(
            database: messageDatabase,
            notification: notification,
            message: message,
            options: options,
            deadline: deadline
          )
          cursor.advance(to: notification)
          if inserted, let message = message {
            if options.once {
              try markReadyWithRetry(
                database: messageDatabase,
                options: options,
                deadline: deadline
              )
            }
            output(message, deliveredAt: notification.deliveredAt)
            if options.once { exit(0) }
          }
        }
        if initial.isEmpty {
          try saveBaselineWithRetry(
            database: messageDatabase,
            cursor: cursor,
            options: options,
            deadline: deadline
          )
        }
      } else {
        cursor = NotificationCursor(baseline: initial)
        try saveBaselineWithRetry(
          database: messageDatabase,
          cursor: cursor,
          options: options,
          deadline: deadline
        )
      }
    }

    let confirmedSourceKey = try notificationSourceKeyWithRetry(
      databasePath: databasePath,
      options: options,
      deadline: deadline
    )
    if confirmedSourceKey != sourceKey {
      sourceKey = confirmedSourceKey
      continue startup
    }
    break startup
  }

  try markReadyWithRetry(database: messageDatabase, options: options, deadline: deadline)
  fputs("监听已启动：\(groups.count) 个指定企业微信群；按 Control-C 停止\n", stderr)
  fflush(stderr)
  var lastHeartbeat = Date().timeIntervalSince1970
  var sourceIsReady = true
  while true {
    // Drain Foundation temporaries on every poll, including retry/skip paths.
    try autoreleasepool {
      if options.once && Date() >= deadline { throw ListenerError.timedOut(options.timeout) }
      Thread.sleep(forTimeInterval: options.pollInterval)
      let observedSourceKey: String
      do {
        observedSourceKey = try validatedNotificationSourceKey(databasePath)
      } catch {
        if sourceIsReady {
          try markSourceUnavailableWithRetry(
            database: messageDatabase,
            options: options,
            deadline: deadline
          )
          sourceIsReady = false
        }
        if options.once && Date() >= deadline { throw ListenerError.timedOut(options.timeout) }
        if waitIfNotificationSourceIsNotReady(databasePath, interval: options.pollInterval) {
          return
        }
        let currentIdentity = try? notificationSourceKey(databasePath)
        if currentIdentity != sourceKey { return }
        guard waitIfDatabaseIsTransient(error, interval: options.pollInterval) else { throw error }
        return
      }
      stopAfterSourceValidationForTestIfRequested()

      if observedSourceKey != sourceKey {
        sourceKey = observedSourceKey
        _ = try bindSourceWithRetry(
          database: messageDatabase,
          sourceKey: sourceKey,
          options: options,
          deadline: deadline
        )
        cursor = NotificationCursor(timestamp: 0, recordID: Int64.min)
        let replacement: [StoredNotification]
        do {
          replacement = try fetchNotifications(
            databasePath: databasePath,
            sourceIdentity: sourceKey,
            fetch: .latest(batchSize)
          )
        } catch {
          try markSourceUnavailableWithRetry(
            database: messageDatabase,
            options: options,
            deadline: deadline
          )
          sourceIsReady = false
          if waitIfNotificationSourceIsNotReady(databasePath, interval: options.pollInterval) {
            return
          }
          if waitIfDatabaseIsTransient(error, interval: options.pollInterval) { return }
          let currentIdentity = try? notificationSourceKey(databasePath)
          if currentIdentity != sourceKey { return }
          throw error
        }
        for notification in replacement where cursor.accepts(notification) {
          let message = decodeMessage(notification, groups: groups)
          let inserted = try persistWithRetry(
            database: messageDatabase,
            notification: notification,
            message: message,
            options: options,
            deadline: deadline
          )
          cursor.advance(to: notification)
          if inserted, let message = message {
            try markReadyWithRetry(
              database: messageDatabase,
              options: options,
              deadline: deadline
            )
            output(message, deliveredAt: notification.deliveredAt)
            if options.once { exit(0) }
          }
        }
        if replacement.isEmpty {
          try saveBaselineWithRetry(
            database: messageDatabase,
            cursor: cursor,
            options: options,
            deadline: deadline
          )
        }
        try markReadyWithRetry(database: messageDatabase, options: options, deadline: deadline)
        sourceIsReady = true
        lastHeartbeat = Date().timeIntervalSince1970
        return
      }

      let records: [StoredNotification]
      do {
        records = try fetchNotifications(
          databasePath: databasePath,
          sourceIdentity: sourceKey,
          fetch: .since(cursor.timestamp, cursor.recordID, batchSize)
        )
      } catch {
        if sourceIsReady {
          try markSourceUnavailableWithRetry(
            database: messageDatabase,
            options: options,
            deadline: deadline
          )
          sourceIsReady = false
        }
        if waitIfNotificationSourceIsNotReady(databasePath, interval: options.pollInterval) {
          return
        }
        let currentIdentity = try? notificationSourceKey(databasePath)
        if currentIdentity != sourceKey { return }
        guard waitIfDatabaseIsTransient(error, interval: options.pollInterval) else { throw error }
        return
      }
      let heartbeatTime = Date().timeIntervalSince1970
      if !sourceIsReady {
        try markReadyWithRetry(database: messageDatabase, options: options, deadline: deadline)
        sourceIsReady = true
        lastHeartbeat = heartbeatTime
      } else if heartbeatTime - lastHeartbeat >= 1 {
        do {
          try messageDatabase.heartbeat(at: heartbeatTime)
          lastHeartbeat = heartbeatTime
        } catch {
          if options.once && Date() >= deadline { throw ListenerError.timedOut(options.timeout) }
          guard waitIfDatabaseIsTransient(error, interval: options.pollInterval) else { throw error }
          return
        }
      }
      for notification in records {
        guard cursor.accepts(notification) else { continue }
        let message = decodeMessage(notification, groups: groups)
        let inserted = try persistWithRetry(
          database: messageDatabase,
          notification: notification,
          message: message,
          options: options,
          deadline: deadline
        )
        cursor.advance(to: notification)
        if inserted, let message = message {
          output(message, deliveredAt: notification.deliveredAt)
          if options.once { exit(0) }
        }
      }
    }
  }
} catch {
  fputs("错误：\(error)\n", stderr)
  exit(1)
}
