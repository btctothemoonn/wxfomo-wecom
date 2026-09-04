import Foundation
import SQLite3

public protocol NotificationRecordReading: AnyObject {
  var databaseURL: URL { get }
  var isReadable: Bool { get }
  func latestRowID() throws -> Int64
  func recentRecords(limit: Int) throws -> [NotificationRecord]
  func batch(after rowID: Int64, limit: Int) throws -> NotificationRecordBatch
}

public enum NotificationDatabaseError: LocalizedError {
  case databaseNotFound(String)
  case databaseUnreadable(String)
  case queryFailed(String)

  public var errorDescription: String? {
    switch self {
    case .databaseNotFound(let path):
      return "通知数据库不存在：\(path)"
    case .databaseUnreadable:
      return "无法读取通知数据库；请为终端或 wxfomo 授予完全磁盘访问权限"
    case .queryFailed(let message):
      return "通知数据库查询失败：\(message)"
    }
  }
}

public enum NotificationDatabaseAvailability: Equatable, Sendable {
  case readable
  case missingFile
  case permissionDenied
  case unreadable(String)
}

public struct AppRecordCount: Equatable, Sendable {
  public let identifier: String
  public let count: Int64

  public init(identifier: String, count: Int64) {
    self.identifier = identifier
    self.count = count
  }
}

public struct NotificationDiagnosticSample: Equatable, Sendable {
  public let table: String
  public let rowID: Int64
  public let deliveredAt: Date
  public let uuid: String?
  public let identifier: String
  public let payloadByteCount: Int
  public let payloadFormat: String
  public let payloadTopLevelKeys: [String]
  public let decoded: Bool
  public let title: String
  public let subtitle: String
  public let body: String

  public init(
    table: String = "record",
    rowID: Int64,
    deliveredAt: Date,
    uuid: String?,
    identifier: String,
    payloadByteCount: Int,
    payloadFormat: String,
    payloadTopLevelKeys: [String],
    decoded: Bool,
    title: String,
    subtitle: String,
    body: String
  ) {
    self.table = table
    self.rowID = rowID
    self.deliveredAt = deliveredAt
    self.uuid = uuid
    self.identifier = identifier
    self.payloadByteCount = payloadByteCount
    self.payloadFormat = payloadFormat
    self.payloadTopLevelKeys = payloadTopLevelKeys
    self.decoded = decoded
    self.title = title
    self.subtitle = subtitle
    self.body = body
  }
}

public struct NotificationTableRowCount: Equatable, Sendable {
  public let table: String
  public let rowCount: Int64
  public let maxRowID: Int64

  public init(table: String, rowCount: Int64, maxRowID: Int64) {
    self.table = table
    self.rowCount = rowCount
    self.maxRowID = maxRowID
  }
}

public struct NotificationTableAppCount: Equatable, Sendable {
  public let table: String
  public let identifier: String
  public let count: Int64

  public init(table: String, identifier: String, count: Int64) {
    self.table = table
    self.identifier = identifier
    self.count = count
  }
}

public struct NotificationDatabaseDiagnostics: Equatable, Sendable {
  public let availability: NotificationDatabaseAvailability
  public let tableNames: [String]
  public let tableSchemas: [String]
  public let tableRowCounts: [NotificationTableRowCount]
  public let tableAppCounts: [NotificationTableAppCount]
  public let totalRecordCount: Int64
  public let maxRowID: Int64
  public let appCounts: [AppRecordCount]
  public let weChatRecordCount: Int64
  public let samples: [NotificationDiagnosticSample]

  public init(
    availability: NotificationDatabaseAvailability,
    tableNames: [String],
    tableSchemas: [String] = [],
    tableRowCounts: [NotificationTableRowCount] = [],
    tableAppCounts: [NotificationTableAppCount] = [],
    totalRecordCount: Int64,
    maxRowID: Int64,
    appCounts: [AppRecordCount],
    weChatRecordCount: Int64,
    samples: [NotificationDiagnosticSample]
  ) {
    self.availability = availability
    self.tableNames = tableNames
    self.tableSchemas = tableSchemas
    self.tableRowCounts = tableRowCounts
    self.tableAppCounts = tableAppCounts
    self.totalRecordCount = totalRecordCount
    self.maxRowID = maxRowID
    self.appCounts = appCounts
    self.weChatRecordCount = weChatRecordCount
    self.samples = samples
  }
}

public final class NotificationDatabaseReader: NotificationRecordReading {
  public static let weChatBundleIdentifier = "com.tencent.xinWeChat"
  public static let weChatTeamIdentifier = "5A4RE8SF68"
  public static let weChatNotificationIdentifiers = [
    weChatBundleIdentifier,
    "\(weChatTeamIdentifier).\(weChatBundleIdentifier)",
  ]
  public static let defaultDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")

  public let databaseURL: URL
  private let decoder: NotificationPayloadDecoder

  public init(
    databaseURL: URL = NotificationDatabaseReader.defaultDatabaseURL,
    decoder: NotificationPayloadDecoder = NotificationPayloadDecoder()
  ) {
    self.databaseURL = databaseURL
    self.decoder = decoder
  }

  public var isReadable: Bool {
    (try? latestRowID()) != nil
  }

  public func availability() -> NotificationDatabaseAvailability {
    let path = databaseURL.path
    guard FileManager.default.fileExists(atPath: path) else {
      return .missingFile
    }
    var database: OpaquePointer?
    let result = sqlite3_open_v2(
      path,
      &database,
      SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
      nil
    )
    guard result == SQLITE_OK, let database else {
      let message = sqlite3_errmsg(database).map(String.init(cString:)) ?? ""
      if let database { sqlite3_close(database) }
      let denied = message.localizedCaseInsensitiveContains("authorization denied")
        || message.localizedCaseInsensitiveContains("operation not permitted")
      return denied ? .permissionDenied : .unreadable(message)
    }
    sqlite3_close(database)
    return .readable
  }

  public func diagnostics(sampleLimit: Int = 10) throws -> NotificationDatabaseDiagnostics {
    let availability = availability()
    var diagnostics = NotificationDatabaseDiagnostics(
      availability: availability,
      tableNames: [],
      totalRecordCount: 0,
      maxRowID: 0,
      appCounts: [],
      weChatRecordCount: 0,
      samples: []
    )
    guard availability == .readable else { return diagnostics }

    try withDatabase { database in
      diagnostics = try Self.collectDiagnostics(
        database,
        databaseURL: databaseURL,
        availability: availability,
        decoder: decoder,
        sampleLimit: sampleLimit
      )
    }
    return diagnostics
  }

  private static func collectDiagnostics(
    _ database: OpaquePointer,
    databaseURL: URL,
    availability: NotificationDatabaseAvailability,
    decoder: NotificationPayloadDecoder,
    sampleLimit: Int
  ) throws -> NotificationDatabaseDiagnostics {
    var tableNames: [String] = []
    do {
      tableNames = try scalarStrings(
        database,
        sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
      )
    } catch {}

    var tableSchemas: [String] = []
    do {
      tableSchemas = try scalarStrings(
        database,
        sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND sql IS NOT NULL ORDER BY name"
      )
    } catch {}

    var tableRowCounts: [NotificationTableRowCount] = []
    var tableAppCounts: [NotificationTableAppCount] = []
    for table in tableNames {
      let quoted = "\"\(table)\""
      let count = (try? scalarInt64(database, sql: "SELECT COUNT(*) FROM \(quoted)")) ?? 0
      let maxRowID =
        (try? scalarInt64(database, sql: "SELECT COALESCE(MAX(rowid), 0) FROM \(quoted)")) ?? 0
      tableRowCounts.append(NotificationTableRowCount(table: table, rowCount: count, maxRowID: maxRowID))
      if let columns = try? tableColumnNames(database, table: table), columns.contains("app_id") {
        if let counts = try? queryTableAppCounts(database, table: table) {
          tableAppCounts.append(contentsOf: counts)
        }
      }
    }

    var totalRecordCount: Int64 = 0
    var maxRowID: Int64 = 0
    if tableNames.contains("record") {
      totalRecordCount = (try? scalarInt64(database, sql: "SELECT COUNT(*) FROM record")) ?? 0
      maxRowID = (try? scalarInt64(database, sql: "SELECT COALESCE(MAX(rowid), 0) FROM record")) ?? 0
    }

    var appCounts: [AppRecordCount] = []
    do {
      appCounts = try queryAppCounts(database)
    } catch {}

    let identifierPlaceholders = Self.weChatNotificationIdentifiers
      .map { _ in "?" }
      .joined(separator: ", ")
    let identifierValues = Self.weChatNotificationIdentifiers

    var weChatRecordCount: Int64 = 0
    do {
      weChatRecordCount =
        (try scalarInt64(
          database,
          sql: """
            SELECT COUNT(*)
            FROM record r
            JOIN app a ON a.app_id = r.app_id
            WHERE a.identifier IN (\(identifierPlaceholders))
            """,
          bindings: identifierValues
        )) ?? 0
    } catch {}

    let samples =
      sampleLimit > 0
      ? try sampleRows(
        database,
        identifierPlaceholders: identifierPlaceholders,
        identifierValues: identifierValues,
        limit: sampleLimit,
        decoder: decoder
      )
      : []

    return NotificationDatabaseDiagnostics(
      availability: availability,
      tableNames: tableNames,
      tableSchemas: tableSchemas,
      tableRowCounts: tableRowCounts,
      tableAppCounts: tableAppCounts,
      totalRecordCount: totalRecordCount,
      maxRowID: maxRowID,
      appCounts: appCounts,
      weChatRecordCount: weChatRecordCount,
      samples: samples
    )
  }

  public func newSamples(in table: String, after rowID: Int64, limit: Int = 50) throws
    -> [NotificationDiagnosticSample]
  {
    try withDatabase { database in
      try Self.queryNewSamples(database, table: table, after: rowID, limit: limit, decoder: decoder)
    }
  }

  private static func queryNewSamples(
    _ database: OpaquePointer,
    table: String,
    after rowID: Int64,
    limit: Int,
    decoder: NotificationPayloadDecoder
  ) throws -> [NotificationDiagnosticSample] {
    let quoted = "\"\(table)\""
    let sql = "SELECT rowid, * FROM \(quoted) WHERE rowid > ? ORDER BY rowid LIMIT ?"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw Self.queryError(database)
    }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_int64(statement, 1, rowID)
    sqlite3_bind_int(statement, 2, Int32(max(1, min(limit, 100))))

    let appMap = try appIdentifierMap(database)
    var samples: [NotificationDiagnosticSample] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else { throw Self.queryError(database) }

      let rowID = sqlite3_column_int64(statement, 0)
      var data = Data()
      var deliveredAt: Date?
      var uuid: String?
      var appID: Int64?
      let columnCount = sqlite3_column_count(statement)
      for column in 0..<columnCount {
        guard let name = sqlite3_column_name(statement, column).map(String.init(cString:)) else {
          continue
        }
        switch name {
        case "data":
          if sqlite3_column_type(statement, column) == SQLITE_BLOB {
            let count = Int(sqlite3_column_bytes(statement, column))
            if let bytes = sqlite3_column_blob(statement, column), count > 0 {
              data = Data(bytes: bytes, count: count)
            }
          } else if let text = sqlite3_column_text(statement, column) {
            data = Data(String(cString: text).utf8)
          }
        case "delivered_date", "requested_date":
          if deliveredAt == nil, sqlite3_column_type(statement, column) != SQLITE_NULL {
            deliveredAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, column))
          }
        case "uuid":
          uuid = stringOrBlob(statement, column: column)
        case "app_id":
          appID = sqlite3_column_int64(statement, column)
        default:
          break
        }
      }

      let resolvedAt = deliveredAt ?? Date(timeIntervalSinceReferenceDate: 0)
      let identifier = appID.flatMap { appMap[$0] } ?? ""
      var title = ""
      var subtitle = ""
      var body = ""
      var decoded = false
      if !data.isEmpty,
        let record = decoder.decode(
          data: data,
          rowID: rowID,
          deliveredAt: resolvedAt,
          uuid: uuid
        )
      {
        decoded = true
        title = record.title
        subtitle = record.subtitle
        body = record.body
      }

      samples.append(
        NotificationDiagnosticSample(
          table: table,
          rowID: rowID,
          deliveredAt: resolvedAt,
          uuid: uuid,
          identifier: identifier,
          payloadByteCount: data.count,
          payloadFormat: payloadFormat(data),
          payloadTopLevelKeys: payloadTopLevelKeys(data),
          decoded: decoded,
          title: title,
          subtitle: subtitle,
          body: body
        )
      )
    }
    return samples
  }

  private static func tableColumnNames(_ database: OpaquePointer, table: String) throws -> [String] {
    let sql = "PRAGMA table_info(\"\(table)\")"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw Self.queryError(database)
    }
    defer { sqlite3_finalize(statement) }
    var names: [String] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else { throw Self.queryError(database) }
      if let name = sqlite3_column_text(statement, 1) {
        names.append(String(cString: name))
      }
    }
    return names
  }

  private static func queryTableAppCounts(
    _ database: OpaquePointer,
    table: String
  ) throws -> [NotificationTableAppCount] {
    let sql = """
      SELECT COALESCE(a.identifier, '<未知 app_id>'), COUNT(*)
      FROM "\(table)" t
      LEFT JOIN app a ON a.app_id = t.app_id
      GROUP BY a.identifier
      ORDER BY COUNT(*) DESC
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw Self.queryError(database)
    }
    defer { sqlite3_finalize(statement) }
    var counts: [NotificationTableAppCount] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else { throw Self.queryError(database) }
      let identifier: String
      if let text = sqlite3_column_text(statement, 0) {
        identifier = String(cString: text)
      } else {
        identifier = "<未知 app_id>"
      }
      counts.append(
        NotificationTableAppCount(
          table: table,
          identifier: identifier,
          count: sqlite3_column_int64(statement, 1)
        )
      )
    }
    return counts
  }

  private static func appIdentifierMap(_ database: OpaquePointer) throws -> [Int64: String] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT app_id, identifier FROM app", -1, &statement, nil)
      == SQLITE_OK,
      let statement
    else {
      throw Self.queryError(database)
    }
    defer { sqlite3_finalize(statement) }
    var map: [Int64: String] = [:]
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else { throw Self.queryError(database) }
      let appID = sqlite3_column_int64(statement, 0)
      if let text = sqlite3_column_text(statement, 1) {
        map[appID] = String(cString: text)
      }
    }
    return map
  }

  private static func sampleRows(
    _ database: OpaquePointer,
    identifierPlaceholders: String,
    identifierValues: [String],
    limit: Int,
    decoder: NotificationPayloadDecoder
  ) throws -> [NotificationDiagnosticSample] {
    let sql = """
      SELECT r.rowid, r.uuid, r.data, r.delivered_date, a.identifier
      FROM record r
      JOIN app a ON a.app_id = r.app_id
      WHERE a.identifier IN (\(identifierPlaceholders))
      ORDER BY r.rowid DESC
      LIMIT ?
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw Self.queryError(database)
    }
    defer { sqlite3_finalize(statement) }

    var bindingIndex: Int32 = 1
    for value in identifierValues {
      sqlite3_bind_text(statement, bindingIndex, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
      bindingIndex += 1
    }
    sqlite3_bind_int(statement, bindingIndex, Int32(max(1, min(limit, 50))))

    var samples: [NotificationDiagnosticSample] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else { throw Self.queryError(database) }

      let rowID = sqlite3_column_int64(statement, 0)
      let uuid = stringOrBlob(statement, column: 1)
      let payloadByteCount = Int(sqlite3_column_bytes(statement, 2))
      let data: Data
      if let bytes = sqlite3_column_blob(statement, 2), payloadByteCount > 0 {
        data = Data(bytes: bytes, count: payloadByteCount)
      } else {
        data = Data()
      }
      let deliveredAt = Date(
        timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 3)
      )
      let identifier = stringOrBlob(statement, column: 4) ?? ""

      var title = ""
      var subtitle = ""
      var body = ""
      var decoded = false
      if let record = decoder.decode(
        data: data,
        rowID: rowID,
        deliveredAt: deliveredAt,
        uuid: uuid
      ) {
        decoded = true
        title = record.title
        subtitle = record.subtitle
        body = record.body
      }

      samples.append(
        NotificationDiagnosticSample(
          rowID: rowID,
          deliveredAt: deliveredAt,
          uuid: uuid,
          identifier: identifier,
          payloadByteCount: payloadByteCount,
          payloadFormat: payloadFormat(data),
          payloadTopLevelKeys: payloadTopLevelKeys(data),
          decoded: decoded,
          title: title,
          subtitle: subtitle,
          body: body
        )
      )
    }
    return samples
  }

  private static func queryAppCounts(_ database: OpaquePointer) throws -> [AppRecordCount] {
    let sql = """
      SELECT COALESCE(a.identifier, '<未知 app_id>'), COUNT(*)
      FROM record r
      LEFT JOIN app a ON a.app_id = r.app_id
      GROUP BY a.identifier
      ORDER BY COUNT(*) DESC
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw Self.queryError(database)
    }
    defer { sqlite3_finalize(statement) }

    var counts: [AppRecordCount] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else { throw Self.queryError(database) }
      let identifier: String
      if let text = sqlite3_column_text(statement, 0) {
        identifier = String(cString: text)
      } else {
        identifier = "<未知 app_id>"
      }
      let count = sqlite3_column_int64(statement, 1)
      counts.append(AppRecordCount(identifier: identifier, count: count))
    }
    return counts
  }

  private static func scalarInt64(
    _ database: OpaquePointer,
    sql: String,
    bindings: [String] = []
  ) throws -> Int64? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw Self.queryError(database)
    }
    defer { sqlite3_finalize(statement) }
    for (index, value) in bindings.enumerated() {
      sqlite3_bind_text(
        statement,
        Int32(index + 1),
        value,
        -1,
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      )
    }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return sqlite3_column_int64(statement, 0)
  }

  private static func scalarStrings(_ database: OpaquePointer, sql: String) throws -> [String] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw Self.queryError(database)
    }
    defer { sqlite3_finalize(statement) }
    var values: [String] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else { throw Self.queryError(database) }
      if let text = sqlite3_column_text(statement, 0) {
        values.append(String(cString: text))
      }
    }
    return values
  }

  private static func payloadFormat(_ data: Data) -> String {
    let bplist: [UInt8] = [0x62, 0x70, 0x6c, 0x69, 0x73, 0x74]
    if data.starts(with: bplist) { return "bplist" }
    if data.first == 0x7b || data.first == 0x5b { return "json" }
    if data.isEmpty { return "empty" }
    return "binary"
  }

  private static func payloadTopLevelKeys(_ data: Data) -> [String] {
    guard
      let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let dictionary = root as? [String: Any]
    else {
      return []
    }
    return dictionary.keys.sorted()
  }

  public func latestRowID() throws -> Int64 {
    try withDatabase { database in
      let sql = """
        SELECT COALESCE(MAX(r.rowid), 0)
        FROM record r
        """
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
        let statement
      else {
        throw Self.queryError(database)
      }
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw Self.queryError(database)
      }
      return sqlite3_column_int64(statement, 0)
    }
  }

  public func records(after rowID: Int64, limit: Int = 200) throws -> [NotificationRecord] {
    try batch(after: rowID, limit: limit).records
  }

  public func batch(after rowID: Int64, limit: Int = 200) throws -> NotificationRecordBatch {
    try queryRecords(
      whereClause: "r.rowid > ?",
      rowID: rowID,
      limit: limit,
      descending: false
    )
  }

  public func recentRecords(limit: Int = 20) throws -> [NotificationRecord] {
    try withDatabase { database in
      let boundedLimit = max(1, min(limit, 500))
      let placeholders = Self.weChatNotificationIdentifiers.map { _ in "?" }
        .joined(separator: ", ")
      let sql = """
        SELECT r.rowid, r.uuid, r.data, r.delivered_date, a.identifier
        FROM record r
        JOIN app a ON a.app_id = r.app_id
        WHERE LOWER(TRIM(a.identifier)) IN (\(placeholders))
        ORDER BY r.rowid DESC
        LIMIT ?
        """
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
        let statement
      else {
        throw Self.queryError(database)
      }
      defer { sqlite3_finalize(statement) }

      var bindingIndex: Int32 = 1
      for identifier in Self.weChatNotificationIdentifiers.map({ $0.lowercased() }) {
        sqlite3_bind_text(
          statement,
          bindingIndex,
          identifier,
          -1,
          unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        )
        bindingIndex += 1
      }
      sqlite3_bind_int(statement, bindingIndex, Int32(boundedLimit))

      var records: [NotificationRecord] = []
      while true {
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { break }
        guard result == SQLITE_ROW else { throw Self.queryError(database) }
        guard
          let bytes = sqlite3_column_blob(statement, 2),
          sqlite3_column_bytes(statement, 2) > 0
        else { continue }
        let data = Data(
          bytes: bytes,
          count: Int(sqlite3_column_bytes(statement, 2))
        )
        let rowID = sqlite3_column_int64(statement, 0)
        let deliveredAt = Date(
          timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 3)
        )
        if let decoded = decoder.decode(
          data: data,
          rowID: rowID,
          deliveredAt: deliveredAt,
          uuid: Self.stringOrBlob(statement, column: 1)
        ) {
          records.append(decoded)
        }
      }
      return records.reversed()
    }
  }

  private func queryRecords(
    whereClause: String,
    rowID: Int64?,
    limit: Int,
    descending: Bool
  ) throws -> NotificationRecordBatch {
    try withDatabase { database in
      let direction = descending ? "DESC" : "ASC"
      let sql = """
        SELECT r.rowid, r.uuid, r.data, r.delivered_date, a.identifier
        FROM record r
        JOIN app a ON a.app_id = r.app_id
        WHERE \(whereClause)
        ORDER BY r.rowid \(direction)
        LIMIT ?
        """
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
        let statement
      else {
        throw Self.queryError(database)
      }
      defer { sqlite3_finalize(statement) }

      var bindingIndex: Int32 = 1
      if let rowID {
        sqlite3_bind_int64(statement, bindingIndex, rowID)
        bindingIndex += 1
      }
      sqlite3_bind_int(statement, bindingIndex, Int32(max(1, min(limit, 5_000))))

      var records: [NotificationRecord] = []
      var lastScannedRowID = rowID ?? 0
      var scannedCount = 0
      var weChatRecordCount = 0
      var payloadDecodeFailureCount = 0
      while true {
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { break }
        guard result == SQLITE_ROW else { throw Self.queryError(database) }

        let rowID = sqlite3_column_int64(statement, 0)
        lastScannedRowID = rowID
        scannedCount += 1
        guard
          let appIdentifier = Self.stringOrBlob(statement, column: 4),
          Self.isWeChatNotificationIdentifier(appIdentifier)
        else {
          continue
        }
        weChatRecordCount += 1
        let uuid = Self.stringOrBlob(statement, column: 1)
        guard
          let bytes = sqlite3_column_blob(statement, 2),
          sqlite3_column_bytes(statement, 2) > 0
        else {
          payloadDecodeFailureCount += 1
          continue
        }
        let data = Data(
          bytes: bytes,
          count: Int(sqlite3_column_bytes(statement, 2))
        )
        let deliveredAt = Date(
          timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 3)
        )
        if let decoded = decoder.decode(
          data: data,
          rowID: rowID,
          deliveredAt: deliveredAt,
          uuid: uuid
        ) {
          records.append(decoded)
        } else {
          payloadDecodeFailureCount += 1
        }
      }
      return NotificationRecordBatch(
        records: records,
        lastScannedRowID: lastScannedRowID,
        scannedCount: scannedCount,
        weChatRecordCount: weChatRecordCount,
        payloadDecodeFailureCount: payloadDecodeFailureCount
      )
    }
  }

  private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
    let path = databaseURL.path
    guard FileManager.default.fileExists(atPath: path) else {
      throw NotificationDatabaseError.databaseNotFound(path)
    }

    var database: OpaquePointer?
    let result = sqlite3_open_v2(
      path,
      &database,
      SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
      nil
    )
    guard result == SQLITE_OK, let database else {
      if let database { sqlite3_close(database) }
      throw NotificationDatabaseError.databaseUnreadable(path)
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 1_000)
    return try body(database)
  }

  private static func queryError(_ database: OpaquePointer) -> NotificationDatabaseError {
    let message = sqlite3_errmsg(database).map(String.init(cString:)) ?? "unknown SQLite error"
    return .queryFailed(message)
  }

  public static func isWeChatNotificationIdentifier(_ identifier: String) -> Bool {
    weChatNotificationIdentifiers.contains {
      $0.caseInsensitiveCompare(
        identifier.trimmingCharacters(in: .whitespacesAndNewlines)
      ) == .orderedSame
    }
  }

  private static func stringOrBlob(_ statement: OpaquePointer, column: Int32) -> String? {
    switch sqlite3_column_type(statement, column) {
    case SQLITE_TEXT:
      guard let text = sqlite3_column_text(statement, column) else { return nil }
      return String(cString: text)
    case SQLITE_BLOB:
      guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
      let count = Int(sqlite3_column_bytes(statement, column))
      let buffer = bytes.bindMemory(to: UInt8.self, capacity: count)
      return (0..<count).map { String(format: "%02x", buffer[$0]) }.joined()
    default:
      return nil
    }
  }
}
