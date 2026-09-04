import Foundation
import SQLite3

public enum MessageStoreError: LocalizedError, Equatable {
  case cannotOpenDatabase(String)
  case configurationFailed(String)
  case schemaTooNew(Int)
  case migrationFailed(version: Int, reason: String)
  case queryFailed(operation: String, reason: String)
  case invalidArgument(String)
  case messageNotFound
  case messageGroupMismatch
  case tagNotFound
  case frozenRangeNotFound
  case decodingFailed(String)

  public var errorDescription: String? {
    switch self {
    case .cannotOpenDatabase(let path):
      return "无法打开消息数据库：\(path)"
    case .configurationFailed(let reason):
      return "消息数据库配置失败：\(reason)"
    case .schemaTooNew(let version):
      return "消息数据库版本 \(version) 高于当前应用支持的版本"
    case .migrationFailed(let version, let reason):
      return "消息数据库迁移到版本 \(version) 失败：\(reason)"
    case .queryFailed(let operation, let reason):
      return "消息数据库操作 \(operation) 失败：\(reason)"
    case .invalidArgument(let field):
      return "消息数据库参数无效：\(field)"
    case .messageNotFound:
      return "指定消息不存在"
    case .messageGroupMismatch:
      return "指定消息不属于该群聊"
    case .tagNotFound:
      return "指定标签不存在"
    case .frozenRangeNotFound:
      return "指定的冻结消息范围不存在"
    case .decodingFailed(let field):
      return "消息数据库字段无法解码：\(field)"
    }
  }
}

public actor MessageStore {
  public static let currentSchemaVersion = 2
  public static let defaultDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/wxFomo", isDirectory: true)
    .appendingPathComponent("messages.sqlite3", isDirectory: false)

  public nonisolated let databaseURL: URL
  public nonisolated let capabilities: MessageStoreCapabilities

  private let database: OpaquePointer

  public init(databaseURL: URL = MessageStore.defaultDatabaseURL) throws {
    try Self.prepareParentDirectory(for: databaseURL)

    var openedDatabase: OpaquePointer?
    let result = sqlite3_open_v2(
      databaseURL.path,
      &openedDatabase,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard result == SQLITE_OK, let openedDatabase else {
      if let openedDatabase { sqlite3_close(openedDatabase) }
      throw MessageStoreError.cannotOpenDatabase(databaseURL.path)
    }

    do {
      sqlite3_extended_result_codes(openedDatabase, 1)
      guard sqlite3_busy_timeout(openedDatabase, 5_000) == SQLITE_OK else {
        throw MessageStoreError.configurationFailed("busy_timeout")
      }
      try Self.execute(openedDatabase, sql: "PRAGMA foreign_keys = ON", operation: "foreign_keys")
      guard try Self.integerPragma(openedDatabase, name: "foreign_keys") == 1 else {
        throw MessageStoreError.configurationFailed("foreign_keys")
      }
      let journalMode = try Self.setJournalModeToWAL(openedDatabase)
      try Self.execute(openedDatabase, sql: "PRAGMA synchronous = NORMAL", operation: "synchronous")
      try Self.execute(
        openedDatabase,
        sql: "PRAGMA wal_autocheckpoint = 1000",
        operation: "wal_autocheckpoint"
      )
      let schemaVersion = try Self.migrate(openedDatabase)
      let ftsAvailable = Self.installFullTextSearchIfAvailable(openedDatabase)

      self.databaseURL = databaseURL
      database = openedDatabase
      capabilities = MessageStoreCapabilities(
        schemaVersion: schemaVersion,
        journalMode: journalMode,
        fullTextSearchAvailable: ftsAvailable
      )
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: databaseURL.path
      )
    } catch {
      sqlite3_close(openedDatabase)
      throw error
    }
  }

  deinit {
    sqlite3_close(database)
  }

  public func insert(_ event: MessageEvent) throws -> MessageInsertResult {
    try validate(event)
    return try withTransaction {
      try insertOne(event)
    }
  }

  public func insert(_ events: [MessageEvent]) throws -> MessageBatchInsertResult {
    for event in events {
      try validate(event)
    }
    guard !events.isEmpty else {
      return MessageBatchInsertResult(insertedCount: 0, existingCount: 0)
    }

    return try withTransaction {
      var insertedCount = 0
      var existingCount = 0
      for event in events {
        switch try insertOne(event) {
        case .inserted: insertedCount += 1
        case .updated: existingCount += 1
        case .existing: existingCount += 1
        }
      }
      return MessageBatchInsertResult(
        insertedCount: insertedCount,
        existingCount: existingCount
      )
    }
  }

  public func messages(matching query: MessageQuery = MessageQuery()) throws -> MessagePage {
    guard (1...500).contains(query.limit) else {
      throw MessageStoreError.invalidArgument("limit")
    }
    if let cursor = query.after, cursor.order != query.order {
      throw MessageStoreError.invalidArgument("after.order")
    }
    try validate(query.scope)

    var fragment = try whereFragment(for: query.scope)
    if let cursor = query.after {
      appendCursor(cursor, order: query.order, to: &fragment)
    }

    let direction = query.order == .newestFirst ? "DESC" : "ASC"
    let sql = """
      SELECT
        m.id, m.event_id, m.group_name, m.sender_display_name, m.sender_stable_id,
        m.content, m.message_type, m.observed_at, m.source_sequence,
        m.attachments_json, m.sender_confidence, m.is_from_self, m.inserted_at
      FROM messages AS m
      \(fragment.sql)
      ORDER BY
        m.observed_at \(direction),
        (m.source_sequence IS NULL) ASC,
        m.source_sequence \(direction),
        m.event_id \(direction),
        m.id \(direction)
      LIMIT ?
      """
    fragment.bindings.append(.int64(Int64(query.limit + 1)))

    var rows = try readMessages(sql: sql, bindings: fragment.bindings)
    let hasMore = rows.count > query.limit
    if hasMore { rows.removeLast() }
    rows = try attachingTags(to: rows)

    let nextCursor: MessagePageCursor?
    if hasMore, let last = rows.last {
      nextCursor = MessagePageCursor(
        storageID: last.storageID,
        eventID: last.event.eventID,
        observedAt: last.event.observedAt,
        sourceSequence: last.event.sourceSequence,
        order: query.order
      )
    } else {
      nextCursor = nil
    }
    return MessagePage(messages: rows, nextCursor: nextCursor, hasMore: hasMore)
  }

  public func messages(eventIDs: [String]) throws -> [StoredMessage] {
    let identifiers = orderedUnique(eventIDs)
    guard identifiers.count <= 10_000 else {
      throw MessageStoreError.invalidArgument("eventIDs")
    }
    guard !identifiers.isEmpty else { return [] }
    for identifier in identifiers {
      _ = try normalizedRequired(identifier, field: "eventIDs")
    }

    var rows: [StoredMessage] = []
    for chunk in identifiers.chunked(maximumSize: 400) {
      let sql = """
        SELECT
          m.id, m.event_id, m.group_name, m.sender_display_name, m.sender_stable_id,
          m.content, m.message_type, m.observed_at, m.source_sequence,
          m.attachments_json, m.sender_confidence, m.is_from_self, m.inserted_at
        FROM messages AS m
        WHERE m.event_id IN (\(placeholders(chunk.count)))
        """
      rows.append(
        contentsOf: try readMessages(
          sql: sql,
          bindings: chunk.map(SQLiteValue.text)
        )
      )
    }
    let tagged = try attachingTags(to: rows)
    let byEventID = Dictionary(uniqueKeysWithValues: tagged.map { ($0.event.eventID, $0) })
    return identifiers.compactMap { byEventID[$0] }
  }

  public func messages(
    aroundEventID eventID: String,
    beforeLimit: Int = 30,
    afterLimit: Int = 30
  ) throws -> [StoredMessage] {
    guard beforeLimit >= 0, afterLimit >= 0,
      beforeLimit + afterLimit + 1 <= 500
    else {
      throw MessageStoreError.invalidArgument("contextLimits")
    }
    guard let focus = try messages(eventIDs: [eventID]).first else {
      throw MessageStoreError.messageNotFound
    }

    let scope = MessageScope(groups: [focus.event.group])
    let older: [StoredMessage]
    if beforeLimit > 0 {
      let cursor = MessagePageCursor(
        storageID: focus.storageID,
        eventID: focus.event.eventID,
        observedAt: focus.event.observedAt,
        sourceSequence: focus.event.sourceSequence,
        order: .newestFirst
      )
      older = try messages(
        matching: MessageQuery(
          scope: scope,
          limit: beforeLimit,
          after: cursor,
          order: .newestFirst
        )
      ).messages
    } else {
      older = []
    }

    let newer: [StoredMessage]
    if afterLimit > 0 {
      let cursor = MessagePageCursor(
        storageID: focus.storageID,
        eventID: focus.event.eventID,
        observedAt: focus.event.observedAt,
        sourceSequence: focus.event.sourceSequence,
        order: .oldestFirst
      )
      newer = try messages(
        matching: MessageQuery(
          scope: scope,
          limit: afterLimit,
          after: cursor,
          order: .oldestFirst
        )
      ).messages
    } else {
      newer = []
    }

    // The feed is newest-first, while the newer-side query is oldest-first.
    return Array(newer.reversed()) + [focus] + older
  }

  public func statistics(in scope: MessageScope = MessageScope()) throws
    -> MessageRangeStatistics
  {
    try validate(scope)
    let fragment = try whereFragment(for: scope)
    let sql = """
      SELECT
        COUNT(*),
        COUNT(DISTINCT m.conversation_id),
        COUNT(DISTINCT CASE
          WHEN NULLIF(TRIM(m.sender_stable_id), '') IS NOT NULL
            THEN 'id:' || m.sender_stable_id
          WHEN NULLIF(TRIM(m.sender_display_name), '') IS NOT NULL
            THEN 'name:' || m.sender_display_name
          ELSE NULL
        END),
        SUM(CASE
          WHEN m.message_type = 'media' AND m.attachment_count = 0 THEN 1 ELSE 0
        END),
        SUM(CASE
          WHEN NULLIF(TRIM(m.sender_stable_id), '') IS NULL
            AND NULLIF(TRIM(m.sender_display_name), '') IS NULL THEN 1 ELSE 0
        END),
        MIN(m.observed_at),
        MAX(m.observed_at)
      FROM messages AS m
      \(fragment.sql)
      """

    let statement = try prepare(sql, operation: "statistics")
    defer { sqlite3_finalize(statement) }
    try bind(fragment.bindings, to: statement, operation: "statistics")
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw queryError("statistics")
    }
    return MessageRangeStatistics(
      capturedCount: Int(sqlite3_column_int64(statement, 0)),
      conversationCount: Int(sqlite3_column_int64(statement, 1)),
      senderCount: Int(sqlite3_column_int64(statement, 2)),
      mediaPlaceholderCount: Int(sqlite3_column_int64(statement, 3)),
      unknownSenderCount: Int(sqlite3_column_int64(statement, 4)),
      earliestObservedAt: optionalDate(statement, column: 5),
      latestObservedAt: optionalDate(statement, column: 6)
    )
  }

  /// Counts locally captured notifications using wxFomo tags and per-group review cursors.
  /// Pending review is not the same as WeChat unread, and these metrics do not measure coverage.
  public func managementMetrics(
    baseScope: MessageScope = MessageScope(),
    priorityMatch: MessageScopeAnyMatch? = nil,
    suppressedTagIDs: Set<String> = [],
    reviewCursors: [ReviewCursor] = []
  ) throws -> MessageManagementMetrics {
    var effectiveBaseScope = baseScope
    effectiveBaseScope.afterReviewCursors = []
    try validate(effectiveBaseScope)

    let suppressedTagIDs = normalizedScopeTagIDs(suppressedTagIDs)
    var unsuppressedScope = effectiveBaseScope
    unsuppressedScope.excludedTagIDs.formUnion(suppressedTagIDs)

    let reviewCursors = try reviewCursors.map { cursor in
      ReviewCursor(
        group: try normalizedRequired(cursor.group, field: "reviewCursors.group"),
        eventID: try normalizedRequired(cursor.eventID, field: "reviewCursors.eventID"),
        observedAt: cursor.observedAt,
        sourceSequence: cursor.sourceSequence,
        updatedAt: cursor.updatedAt
      )
    }
    var pendingReviewScope = unsuppressedScope
    pendingReviewScope.afterReviewCursors = reviewCursors
    try validate(pendingReviewScope)

    let priorityMatch = normalizedScopeAnyMatch(priorityMatch)
    return try withReadTransaction {
      let baseFragment = try whereFragment(for: effectiveBaseScope)
      let unsuppressedFragment = try whereFragment(for: unsuppressedScope)
      let pendingReviewFragment = try whereFragment(for: pendingReviewScope)

      let baseCapturedCount = try countMessages(
        matching: baseFragment,
        operation: "management_base_count"
      )
      let unsuppressedCapturedCount = try countMessages(
        matching: unsuppressedFragment,
        operation: "management_unsuppressed_count"
      )

      let priorityCapturedCount: Int
      if let priorityMatch {
        var priorityFragment = unsuppressedFragment
        appendAnyMatchScope(priorityMatch, to: &priorityFragment)
        priorityCapturedCount = try countMessages(
          matching: priorityFragment,
          operation: "management_priority_count"
        )
      } else {
        priorityCapturedCount = 0
      }

      let pendingReview = try countAndOldestMessage(
        matching: pendingReviewFragment,
        operation: "management_pending_review"
      )
      return MessageManagementMetrics(
        baseCapturedCount: baseCapturedCount,
        unsuppressedCapturedCount: unsuppressedCapturedCount,
        priorityCapturedCount: priorityCapturedCount,
        suppressedCapturedCount: max(0, baseCapturedCount - unsuppressedCapturedCount),
        pendingReviewCount: pendingReview.count,
        oldestPendingReviewObservedAt: pendingReview.oldestObservedAt
      )
    }
  }

  public func flowAnalytics(
    in scope: MessageScope = MessageScope(),
    topLimit: Int = 10
  ) throws -> MessageFlowAnalytics {
    guard (1...100).contains(topLimit) else {
      throw MessageStoreError.invalidArgument("topLimit")
    }
    try validate(scope)

    return try withReadTransaction {
      let statistics = try statistics(in: scope)
      let granularity = flowBucketGranularity(in: scope, statistics: statistics)
      guard statistics.capturedCount > 0 else {
        return MessageFlowAnalytics(
          statistics: statistics,
          bucketGranularity: granularity,
          timeBuckets: [],
          groupDistribution: [],
          senderDistribution: [],
          messageTypeDistribution: []
        )
      }

      let timeBuckets = try flowTimeBuckets(in: scope, granularity: granularity)
      let groupDistribution = try flowGroupDistribution(in: scope, limit: topLimit)
      let senderDistribution = try flowSenderDistribution(in: scope, limit: topLimit)
      let messageTypeDistribution = try flowMessageTypeDistribution(in: scope)
      return MessageFlowAnalytics(
        statistics: statistics,
        bucketGranularity: granularity,
        timeBuckets: timeBuckets,
        groupDistribution: groupDistribution,
        senderDistribution: senderDistribution,
        messageTypeDistribution: messageTypeDistribution
      )
    }
  }

  public func reviewCursor(forGroup group: String) throws -> ReviewCursor? {
    let normalizedGroup = try normalizedRequired(group, field: "group")
    let sql = """
      SELECT c.group_name, r.last_event_id, r.last_observed_at,
        r.last_source_sequence, r.updated_at
      FROM review_cursors AS r
      JOIN conversations AS c ON c.id = r.conversation_id
      WHERE c.group_name = ?
      """
    let statement = try prepare(sql, operation: "review_cursor")
    defer { sqlite3_finalize(statement) }
    try bind([.text(normalizedGroup)], to: statement, operation: "review_cursor")
    let result = sqlite3_step(statement)
    guard result == SQLITE_ROW else {
      if result == SQLITE_DONE { return nil }
      throw queryError("review_cursor")
    }
    return ReviewCursor(
      group: requiredText(statement, column: 0),
      eventID: requiredText(statement, column: 1),
      observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
      sourceSequence: optionalInt64(statement, column: 3),
      updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
    )
  }

  @discardableResult
  public func setReviewCursor(group: String, eventID: String) throws -> ReviewCursor {
    let normalizedGroup = try normalizedRequired(group, field: "group")
    let normalizedEventID = try normalizedRequired(eventID, field: "eventID")
    let now = Date()

    try withTransaction {
      let lookup = try prepare(
        """
        SELECT m.id, m.conversation_id, m.group_name, m.observed_at, m.source_sequence
        FROM messages AS m
        WHERE m.event_id = ?
        """,
        operation: "set_review_cursor_lookup"
      )
      defer { sqlite3_finalize(lookup) }
      try bind([.text(normalizedEventID)], to: lookup, operation: "set_review_cursor_lookup")
      guard sqlite3_step(lookup) == SQLITE_ROW else {
        throw MessageStoreError.messageNotFound
      }
      guard requiredText(lookup, column: 2) == normalizedGroup else {
        throw MessageStoreError.messageGroupMismatch
      }
      let messageID = sqlite3_column_int64(lookup, 0)
      let conversationID = sqlite3_column_int64(lookup, 1)
      let observedAt = sqlite3_column_double(lookup, 3)
      let sourceSequence = optionalInt64(lookup, column: 4)

      let statement = try prepare(
        """
        INSERT INTO review_cursors(
          conversation_id, last_ingest_id, last_event_id, last_observed_at,
          last_source_sequence, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(conversation_id) DO UPDATE SET
          last_ingest_id = excluded.last_ingest_id,
          last_event_id = excluded.last_event_id,
          last_observed_at = excluded.last_observed_at,
          last_source_sequence = excluded.last_source_sequence,
          updated_at = excluded.updated_at
        WHERE excluded.last_observed_at > review_cursors.last_observed_at
          OR (
            excluded.last_observed_at = review_cursors.last_observed_at
            AND (
              (review_cursors.last_source_sequence IS NOT NULL
                AND excluded.last_source_sequence IS NULL)
              OR (
                review_cursors.last_source_sequence IS NOT NULL
                AND excluded.last_source_sequence IS NOT NULL
                AND excluded.last_source_sequence > review_cursors.last_source_sequence
              )
              OR (
                (
                  (review_cursors.last_source_sequence IS NULL
                    AND excluded.last_source_sequence IS NULL)
                  OR review_cursors.last_source_sequence = excluded.last_source_sequence
                )
                AND excluded.last_event_id > review_cursors.last_event_id
              )
            )
          )
        """,
        operation: "set_review_cursor"
      )
      defer { sqlite3_finalize(statement) }
      try bind(
        [
          .int64(conversationID), .int64(messageID), .text(normalizedEventID),
          .double(observedAt), sourceSequence.map(SQLiteValue.int64) ?? .null,
          .double(now.timeIntervalSince1970),
        ],
        to: statement,
        operation: "set_review_cursor"
      )
      guard sqlite3_step(statement) == SQLITE_DONE else {
        throw queryError("set_review_cursor")
      }
    }

    guard let cursor = try reviewCursor(forGroup: normalizedGroup) else {
      throw queryError("set_review_cursor_result")
    }
    return cursor
  }

  public func clearReviewCursor(forGroup group: String) throws {
    let normalizedGroup = try normalizedRequired(group, field: "group")
    let statement = try prepare(
      """
      DELETE FROM review_cursors
      WHERE conversation_id = (SELECT id FROM conversations WHERE group_name = ?)
      """,
      operation: "clear_review_cursor"
    )
    defer { sqlite3_finalize(statement) }
    try bind([.text(normalizedGroup)], to: statement, operation: "clear_review_cursor")
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw queryError("clear_review_cursor")
    }
  }

  @discardableResult
  public func upsertTag(name: String, colorHex: String? = nil) throws -> MessageTag {
    let trimmedName = try normalizedRequired(name, field: "tag.name")
    let normalizedName = trimmedName.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
    let now = Date()
    let proposedID = UUID().uuidString.lowercased()
    let statement = try prepare(
      """
      INSERT INTO tags(id, name, normalized_name, color_hex, created_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(normalized_name) DO UPDATE SET
        name = excluded.name,
        color_hex = excluded.color_hex
      RETURNING id, name, color_hex, created_at
      """,
      operation: "upsert_tag"
    )
    defer { sqlite3_finalize(statement) }
    try bind(
      [
        .text(proposedID), .text(trimmedName), .text(normalizedName),
        colorHex.map(SQLiteValue.text) ?? .null, .double(now.timeIntervalSince1970),
      ],
      to: statement,
      operation: "upsert_tag"
    )
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw queryError("upsert_tag")
    }
    return decodeTag(statement)
  }

  public func tags() throws -> [MessageTag] {
    let statement = try prepare(
      "SELECT id, name, color_hex, created_at FROM tags ORDER BY normalized_name, id",
      operation: "list_tags"
    )
    defer { sqlite3_finalize(statement) }
    var results: [MessageTag] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW: results.append(decodeTag(statement))
      case SQLITE_DONE: return results
      default: throw queryError("list_tags")
      }
    }
  }

  @discardableResult
  public func setTag(_ tagID: String, onEventIDs eventIDs: [String]) throws -> Int {
    let tagID = try normalizedRequired(tagID, field: "tagID")
    let uniqueEventIDs = orderedUnique(eventIDs)
    guard !uniqueEventIDs.isEmpty else { return 0 }
    guard try tagExists(tagID) else { throw MessageStoreError.tagNotFound }

    return try withTransaction {
      var changed = 0
      let statement = try prepare(
        """
        INSERT OR IGNORE INTO message_tags(message_id, tag_id, tagged_at)
        SELECT id, ?, ? FROM messages WHERE event_id = ?
        """,
        operation: "set_tag"
      )
      defer { sqlite3_finalize(statement) }
      for eventID in uniqueEventIDs {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        try bind(
          [.text(tagID), .double(Date().timeIntervalSince1970), .text(eventID)],
          to: statement,
          operation: "set_tag"
        )
        guard sqlite3_step(statement) == SQLITE_DONE else { throw queryError("set_tag") }
        changed += Int(sqlite3_changes(database))
      }
      return changed
    }
  }

  @discardableResult
  public func removeTag(_ tagID: String, fromEventIDs eventIDs: [String]) throws -> Int {
    let tagID = try normalizedRequired(tagID, field: "tagID")
    let uniqueEventIDs = orderedUnique(eventIDs)
    guard !uniqueEventIDs.isEmpty else { return 0 }

    return try withTransaction {
      var changed = 0
      let statement = try prepare(
        """
        DELETE FROM message_tags
        WHERE tag_id = ? AND message_id = (SELECT id FROM messages WHERE event_id = ?)
        """,
        operation: "remove_tag"
      )
      defer { sqlite3_finalize(statement) }
      for eventID in uniqueEventIDs {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        try bind([.text(tagID), .text(eventID)], to: statement, operation: "remove_tag")
        guard sqlite3_step(statement) == SQLITE_DONE else { throw queryError("remove_tag") }
        changed += Int(sqlite3_changes(database))
      }
      return changed
    }
  }

  public func tags(forEventID eventID: String) throws -> [MessageTag] {
    let eventID = try normalizedRequired(eventID, field: "eventID")
    let statement = try prepare(
      """
      SELECT t.id, t.name, t.color_hex, t.created_at
      FROM tags AS t
      JOIN message_tags AS mt ON mt.tag_id = t.id
      JOIN messages AS m ON m.id = mt.message_id
      WHERE m.event_id = ?
      ORDER BY t.normalized_name, t.id
      """,
      operation: "message_tags"
    )
    defer { sqlite3_finalize(statement) }
    try bind([.text(eventID)], to: statement, operation: "message_tags")
    var results: [MessageTag] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW: results.append(decodeTag(statement))
      case SQLITE_DONE: return results
      default: throw queryError("message_tags")
      }
    }
  }

  public func freeze(scope: MessageScope = MessageScope()) throws -> FrozenMessageRange {
    try validate(scope)
    let fragment = try whereFragment(for: scope)
    let rangeID = UUID().uuidString.lowercased()
    let createdAt = Date()

    return try withTransaction {
      let selection = try prepare(
        """
        SELECT m.id, m.event_id, m.observed_at
        FROM messages AS m
        \(fragment.sql)
        ORDER BY m.observed_at ASC, (m.source_sequence IS NULL) ASC,
          m.source_sequence ASC, m.event_id ASC, m.id ASC
        """,
        operation: "freeze_select"
      )
      defer { sqlite3_finalize(selection) }
      try bind(fragment.bindings, to: selection, operation: "freeze_select")

      var rows: [(storageID: Int64, eventID: String, observedAt: Date)] = []
      while true {
        switch sqlite3_step(selection) {
        case SQLITE_ROW:
          rows.append((
            sqlite3_column_int64(selection, 0),
            requiredText(selection, column: 1),
            Date(timeIntervalSince1970: sqlite3_column_double(selection, 2))
          ))
        case SQLITE_DONE:
          break
        default:
          throw queryError("freeze_select")
        }
        if sqlite3_data_count(selection) == 0 { break }
      }

      let scopeData = try encode(scope, field: "scope")
      let header = try prepare(
        """
        INSERT INTO frozen_message_ranges(
          id, created_at, scope_json, message_count, earliest_observed_at, latest_observed_at
        ) VALUES (?, ?, ?, ?, ?, ?)
        """,
        operation: "freeze_header"
      )
      defer { sqlite3_finalize(header) }
      try bind(
        [
          .text(rangeID), .double(createdAt.timeIntervalSince1970), .blob(scopeData),
          .int64(Int64(rows.count)),
          rows.first.map { .double($0.observedAt.timeIntervalSince1970) } ?? .null,
          rows.last.map { .double($0.observedAt.timeIntervalSince1970) } ?? .null,
        ],
        to: header,
        operation: "freeze_header"
      )
      guard sqlite3_step(header) == SQLITE_DONE else { throw queryError("freeze_header") }

      let item = try prepare(
        """
        INSERT INTO frozen_message_items(range_id, ordinal, message_id, event_id)
        VALUES (?, ?, ?, ?)
        """,
        operation: "freeze_items"
      )
      defer { sqlite3_finalize(item) }
      for (index, row) in rows.enumerated() {
        sqlite3_reset(item)
        sqlite3_clear_bindings(item)
        try bind(
          [.text(rangeID), .int64(Int64(index)), .int64(row.storageID), .text(row.eventID)],
          to: item,
          operation: "freeze_items"
        )
        guard sqlite3_step(item) == SQLITE_DONE else { throw queryError("freeze_items") }
      }

      return FrozenMessageRange(
        id: rangeID,
        createdAt: createdAt,
        scope: scope,
        eventIDs: rows.map(\.eventID),
        earliestObservedAt: rows.first?.observedAt,
        latestObservedAt: rows.last?.observedAt
      )
    }
  }

  public func freeze(
    eventIDs: [String],
    scope: MessageScope = MessageScope()
  ) throws -> FrozenMessageRange {
    try validate(scope)
    let uniqueEventIDs = orderedUnique(eventIDs)
    guard !uniqueEventIDs.isEmpty, uniqueEventIDs.count <= 10_000 else {
      throw MessageStoreError.invalidArgument("eventIDs")
    }
    guard uniqueEventIDs.allSatisfy({
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }) else {
      throw MessageStoreError.invalidArgument("eventIDs")
    }

    let rangeID = UUID().uuidString.lowercased()
    let createdAt = Date()
    return try withTransaction {
      let lookup = try prepare(
        "SELECT id, event_id, observed_at FROM messages WHERE event_id = ?",
        operation: "freeze_ids_select"
      )
      defer { sqlite3_finalize(lookup) }

      var rows: [(storageID: Int64, eventID: String, observedAt: Date)] = []
      for eventID in uniqueEventIDs {
        sqlite3_reset(lookup)
        sqlite3_clear_bindings(lookup)
        try bind([.text(eventID)], to: lookup, operation: "freeze_ids_select")
        guard sqlite3_step(lookup) == SQLITE_ROW else {
          throw MessageStoreError.messageNotFound
        }
        rows.append((
          sqlite3_column_int64(lookup, 0),
          requiredText(lookup, column: 1),
          Date(timeIntervalSince1970: sqlite3_column_double(lookup, 2))
        ))
      }

      let earliest = rows.map(\.observedAt).min()
      let latest = rows.map(\.observedAt).max()
      let scopeData = try encode(scope, field: "scope")
      let header = try prepare(
        """
        INSERT INTO frozen_message_ranges(
          id, created_at, scope_json, message_count, earliest_observed_at, latest_observed_at
        ) VALUES (?, ?, ?, ?, ?, ?)
        """,
        operation: "freeze_ids_header"
      )
      defer { sqlite3_finalize(header) }
      try bind(
        [
          .text(rangeID), .double(createdAt.timeIntervalSince1970), .blob(scopeData),
          .int64(Int64(rows.count)),
          earliest.map { .double($0.timeIntervalSince1970) } ?? .null,
          latest.map { .double($0.timeIntervalSince1970) } ?? .null,
        ],
        to: header,
        operation: "freeze_ids_header"
      )
      guard sqlite3_step(header) == SQLITE_DONE else {
        throw queryError("freeze_ids_header")
      }

      let item = try prepare(
        """
        INSERT INTO frozen_message_items(range_id, ordinal, message_id, event_id)
        VALUES (?, ?, ?, ?)
        """,
        operation: "freeze_ids_items"
      )
      defer { sqlite3_finalize(item) }
      for (index, row) in rows.enumerated() {
        sqlite3_reset(item)
        sqlite3_clear_bindings(item)
        try bind(
          [.text(rangeID), .int64(Int64(index)), .int64(row.storageID), .text(row.eventID)],
          to: item,
          operation: "freeze_ids_items"
        )
        guard sqlite3_step(item) == SQLITE_DONE else {
          throw queryError("freeze_ids_items")
        }
      }

      return FrozenMessageRange(
        id: rangeID,
        createdAt: createdAt,
        scope: scope,
        eventIDs: rows.map(\.eventID),
        earliestObservedAt: earliest,
        latestObservedAt: latest
      )
    }
  }

  public func frozenRange(id: String) throws -> FrozenMessageRange? {
    let id = try normalizedRequired(id, field: "frozenRange.id")
    let statement = try prepare(
      """
      SELECT created_at, scope_json, earliest_observed_at, latest_observed_at
      FROM frozen_message_ranges
      WHERE id = ?
      """,
      operation: "frozen_range"
    )
    defer { sqlite3_finalize(statement) }
    try bind([.text(id)], to: statement, operation: "frozen_range")
    let result = sqlite3_step(statement)
    guard result == SQLITE_ROW else {
      if result == SQLITE_DONE { return nil }
      throw queryError("frozen_range")
    }
    let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    let scopeData = requiredData(statement, column: 1)
    let scope: MessageScope = try decode(MessageScope.self, from: scopeData, field: "scope")
    let earliest = optionalDate(statement, column: 2)
    let latest = optionalDate(statement, column: 3)
    let eventIDs = try frozenEventIDs(id: id)
    return FrozenMessageRange(
      id: id,
      createdAt: createdAt,
      scope: scope,
      eventIDs: eventIDs,
      earliestObservedAt: earliest,
      latestObservedAt: latest
    )
  }

  public func frozenRanges(limit: Int = 100) throws -> [FrozenMessageRange] {
    guard (1...500).contains(limit) else {
      throw MessageStoreError.invalidArgument("limit")
    }
    let statement = try prepare(
      """
      SELECT id FROM frozen_message_ranges
      ORDER BY created_at DESC, id DESC
      LIMIT ?
      """,
      operation: "frozen_ranges"
    )
    defer { sqlite3_finalize(statement) }
    try bind([.int64(Int64(limit))], to: statement, operation: "frozen_ranges")
    var ids: [String] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW: ids.append(requiredText(statement, column: 0))
      case SQLITE_DONE:
        return try ids.compactMap { try frozenRange(id: $0) }
      default: throw queryError("frozen_ranges")
      }
    }
  }

  public func messages(inFrozenRange id: String) throws -> [StoredMessage] {
    let id = try normalizedRequired(id, field: "frozenRange.id")
    guard try frozenRangeExists(id) else { throw MessageStoreError.frozenRangeNotFound }
    let rows = try readMessages(
      sql: """
        SELECT
          m.id, m.event_id, m.group_name, m.sender_display_name, m.sender_stable_id,
          m.content, m.message_type, m.observed_at, m.source_sequence,
          m.attachments_json, m.sender_confidence, m.is_from_self, m.inserted_at
        FROM frozen_message_items AS i
        JOIN messages AS m ON m.id = i.message_id
        WHERE i.range_id = ?
        ORDER BY i.ordinal ASC
        """,
      bindings: [.text(id)]
    )
    return try attachingTags(to: rows)
  }

  public func deleteFrozenRange(id: String) throws {
    let id = try normalizedRequired(id, field: "frozenRange.id")
    let statement = try prepare(
      "DELETE FROM frozen_message_ranges WHERE id = ?",
      operation: "delete_frozen_range"
    )
    defer { sqlite3_finalize(statement) }
    try bind([.text(id)], to: statement, operation: "delete_frozen_range")
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw queryError("delete_frozen_range")
    }
  }
}

private extension MessageStore {
  enum SQLiteValue {
    case null
    case int64(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
  }

  struct SQLFragment {
    var clauses: [String] = []
    var bindings: [SQLiteValue] = []

    var sql: String {
      clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
    }
  }

  struct Migration {
    let version: Int
    let sql: String
  }

  static var migrations: [Migration] {
    [
      Migration(
        version: 1,
        sql: """
          CREATE TABLE schema_migrations(
            version INTEGER PRIMARY KEY,
            applied_at REAL NOT NULL
          );

          CREATE TABLE conversations(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source TEXT NOT NULL DEFAULT 'wechat',
            group_name TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            last_message_at REAL,
            message_count INTEGER NOT NULL DEFAULT 0,
            UNIQUE(source, group_name)
          );

          CREATE TABLE messages(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_id TEXT NOT NULL UNIQUE,
            conversation_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE RESTRICT,
            group_name TEXT NOT NULL,
            sender_display_name TEXT,
            sender_stable_id TEXT,
            content TEXT NOT NULL,
            message_type TEXT NOT NULL CHECK(message_type IN ('text', 'media', 'system', 'unknown')),
            observed_at REAL NOT NULL,
            source_sequence INTEGER,
            attachments_json BLOB NOT NULL,
            attachment_count INTEGER NOT NULL DEFAULT 0,
            sender_confidence TEXT NOT NULL,
            is_from_self INTEGER NOT NULL CHECK(is_from_self IN (0, 1)),
            inserted_at REAL NOT NULL,
            record_version INTEGER NOT NULL DEFAULT 1
          );

          CREATE INDEX messages_timeline_idx
            ON messages(observed_at, (source_sequence IS NULL), source_sequence, event_id, id);
          CREATE INDEX messages_conversation_timeline_idx
            ON messages(conversation_id, observed_at, (source_sequence IS NULL), source_sequence, event_id);
          CREATE INDEX messages_sender_stable_idx ON messages(sender_stable_id);
          CREATE INDEX messages_sender_display_idx ON messages(sender_display_name);
          CREATE INDEX messages_type_time_idx ON messages(message_type, observed_at);

          CREATE TABLE review_cursors(
            conversation_id INTEGER PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
            last_ingest_id INTEGER NOT NULL,
            last_event_id TEXT NOT NULL,
            last_observed_at REAL NOT NULL,
            last_source_sequence INTEGER,
            updated_at REAL NOT NULL
          );

          CREATE TABLE tags(
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            normalized_name TEXT NOT NULL UNIQUE,
            color_hex TEXT,
            created_at REAL NOT NULL
          );

          CREATE TABLE message_tags(
            message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
            tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
            tagged_at REAL NOT NULL,
            PRIMARY KEY(message_id, tag_id)
          );
          CREATE INDEX message_tags_tag_idx ON message_tags(tag_id, message_id);
          """
      ),
      Migration(
        version: 2,
        sql: """
          CREATE TABLE frozen_message_ranges(
            id TEXT PRIMARY KEY,
            created_at REAL NOT NULL,
            scope_json BLOB NOT NULL,
            message_count INTEGER NOT NULL,
            earliest_observed_at REAL,
            latest_observed_at REAL
          );

          CREATE TABLE frozen_message_items(
            range_id TEXT NOT NULL REFERENCES frozen_message_ranges(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE RESTRICT,
            event_id TEXT NOT NULL,
            PRIMARY KEY(range_id, ordinal),
            UNIQUE(range_id, message_id),
            UNIQUE(range_id, event_id)
          );
          CREATE INDEX frozen_message_items_message_idx
            ON frozen_message_items(message_id, range_id);
          """
      ),
    ]
  }

  static func prepareParentDirectory(for databaseURL: URL) throws {
    let directory = databaseURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      throw MessageStoreError.cannotOpenDatabase(databaseURL.path)
    }
  }

  static func setJournalModeToWAL(_ database: OpaquePointer) throws -> String {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA journal_mode = WAL", -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw configurationError(database, operation: "journal_mode")
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      let text = sqlite3_column_text(statement, 0)
    else {
      throw configurationError(database, operation: "journal_mode")
    }
    let mode = String(cString: text).lowercased()
    guard mode == "wal" else {
      throw MessageStoreError.configurationFailed("journal_mode=\(mode)")
    }
    return mode
  }

  static func integerPragma(_ database: OpaquePointer, name: String) throws -> Int {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA \(name)", -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw configurationError(database, operation: name)
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw configurationError(database, operation: name)
    }
    return Int(sqlite3_column_int(statement, 0))
  }

  static func migrate(_ database: OpaquePointer) throws -> Int {
    let currentVersion = try integerPragma(database, name: "user_version")
    guard currentVersion <= currentSchemaVersion else {
      throw MessageStoreError.schemaTooNew(currentVersion)
    }

    for migration in migrations where migration.version > currentVersion {
      do {
        try execute(database, sql: "BEGIN IMMEDIATE", operation: "migration_begin")
        try execute(database, sql: migration.sql, operation: "migration_ddl")
        try execute(
          database,
          sql: """
            INSERT INTO schema_migrations(version, applied_at)
            VALUES (\(migration.version), \(Date().timeIntervalSince1970))
            """,
          operation: "migration_record"
        )
        try execute(
          database,
          sql: "PRAGMA user_version = \(migration.version)",
          operation: "migration_version"
        )
        try execute(database, sql: "COMMIT", operation: "migration_commit")
      } catch {
        try? execute(database, sql: "ROLLBACK", operation: "migration_rollback")
        let reason = sqliteMessage(database)
        throw MessageStoreError.migrationFailed(version: migration.version, reason: reason)
      }
    }
    return currentSchemaVersion
  }

  static func installFullTextSearchIfAvailable(_ database: OpaquePointer) -> Bool {
    let existed = (try? objectExists(database, type: "table", name: "messages_fts")) ?? false
    do {
      try execute(
        database,
        sql: """
          CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
            content,
            group_name,
            sender_display_name,
            content = 'messages',
            content_rowid = 'id',
            tokenize = 'unicode61 remove_diacritics 2'
          )
          """,
        operation: "fts_create"
      )
      try execute(
        database,
        sql: """
          CREATE TRIGGER IF NOT EXISTS messages_fts_insert AFTER INSERT ON messages BEGIN
            INSERT INTO messages_fts(rowid, content, group_name, sender_display_name)
            VALUES (new.id, new.content, new.group_name, COALESCE(new.sender_display_name, ''));
          END;

          CREATE TRIGGER IF NOT EXISTS messages_fts_delete AFTER DELETE ON messages BEGIN
            INSERT INTO messages_fts(messages_fts, rowid, content, group_name, sender_display_name)
            VALUES ('delete', old.id, old.content, old.group_name, COALESCE(old.sender_display_name, ''));
          END;

          CREATE TRIGGER IF NOT EXISTS messages_fts_update AFTER UPDATE OF content, group_name, sender_display_name ON messages BEGIN
            INSERT INTO messages_fts(messages_fts, rowid, content, group_name, sender_display_name)
            VALUES ('delete', old.id, old.content, old.group_name, COALESCE(old.sender_display_name, ''));
            INSERT INTO messages_fts(rowid, content, group_name, sender_display_name)
            VALUES (new.id, new.content, new.group_name, COALESCE(new.sender_display_name, ''));
          END;
          """,
        operation: "fts_triggers"
      )
      if !existed {
        try execute(
          database,
          sql: "INSERT INTO messages_fts(messages_fts) VALUES ('rebuild')",
          operation: "fts_rebuild"
        )
      }
      return true
    } catch {
      try? execute(database, sql: "DROP TRIGGER IF EXISTS messages_fts_insert", operation: "fts_drop")
      try? execute(database, sql: "DROP TRIGGER IF EXISTS messages_fts_delete", operation: "fts_drop")
      try? execute(database, sql: "DROP TRIGGER IF EXISTS messages_fts_update", operation: "fts_drop")
      try? execute(database, sql: "DROP TABLE IF EXISTS messages_fts", operation: "fts_drop")
      return false
    }
  }

  static func objectExists(
    _ database: OpaquePointer,
    type: String,
    name: String
  ) throws -> Bool {
    var statement: OpaquePointer?
    let sql = "SELECT 1 FROM sqlite_master WHERE type = ? AND name = ? LIMIT 1"
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw configurationError(database, operation: "schema_probe")
    }
    defer { sqlite3_finalize(statement) }
    try bindStatic([.text(type), .text(name)], to: statement, database: database)
    return sqlite3_step(statement) == SQLITE_ROW
  }

  static func execute(_ database: OpaquePointer, sql: String, operation: String) throws {
    var errorPointer: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &errorPointer)
    if let errorPointer { sqlite3_free(errorPointer) }
    guard result == SQLITE_OK else {
      throw MessageStoreError.queryFailed(
        operation: operation,
        reason: sqliteMessage(database)
      )
    }
  }

  static func configurationError(_ database: OpaquePointer, operation: String)
    -> MessageStoreError
  {
    .configurationFailed("\(operation): \(sqliteMessage(database))")
  }

  static func sqliteMessage(_ database: OpaquePointer) -> String {
    sqlite3_errmsg(database).map(String.init(cString:)) ?? "unknown SQLite error"
  }

  static func bindStatic(
    _ values: [SQLiteValue],
    to statement: OpaquePointer,
    database: OpaquePointer
  ) throws {
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch value {
      case .null:
        result = sqlite3_bind_null(statement, index)
      case .int64(let value):
        result = sqlite3_bind_int64(statement, index, value)
      case .double(let value):
        result = sqlite3_bind_double(statement, index, value)
      case .text(let value):
        result = value.withCString {
          sqlite3_bind_text(statement, index, $0, -1, sqliteTransientDestructor)
        }
      case .blob(let value):
        result = value.withUnsafeBytes {
          sqlite3_bind_blob(
            statement,
            index,
            $0.baseAddress,
            Int32($0.count),
            sqliteTransientDestructor
          )
        }
      }
      guard result == SQLITE_OK else {
        throw MessageStoreError.queryFailed(
          operation: "bind",
          reason: sqliteMessage(database)
        )
      }
    }
  }

  static var sqliteTransientDestructor: sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  }

  func prepare(_ sql: String, operation: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw queryError(operation)
    }
    return statement
  }

  func bind(_ values: [SQLiteValue], to statement: OpaquePointer, operation: String) throws {
    do {
      try Self.bindStatic(values, to: statement, database: database)
    } catch {
      throw queryError(operation)
    }
  }

  func queryError(_ operation: String) -> MessageStoreError {
    .queryFailed(operation: operation, reason: Self.sqliteMessage(database))
  }

  func countMessages(matching fragment: SQLFragment, operation: String) throws -> Int {
    let statement = try prepare(
      "SELECT COUNT(*) FROM messages AS m \(fragment.sql)",
      operation: operation
    )
    defer { sqlite3_finalize(statement) }
    try bind(fragment.bindings, to: statement, operation: operation)
    guard sqlite3_step(statement) == SQLITE_ROW else { throw queryError(operation) }
    return Int(sqlite3_column_int64(statement, 0))
  }

  func countAndOldestMessage(
    matching fragment: SQLFragment,
    operation: String
  ) throws -> (count: Int, oldestObservedAt: Date?) {
    let statement = try prepare(
      "SELECT COUNT(*), MIN(m.observed_at) FROM messages AS m \(fragment.sql)",
      operation: operation
    )
    defer { sqlite3_finalize(statement) }
    try bind(fragment.bindings, to: statement, operation: operation)
    guard sqlite3_step(statement) == SQLITE_ROW else { throw queryError(operation) }
    return (
      count: Int(sqlite3_column_int64(statement, 0)),
      oldestObservedAt: optionalDate(statement, column: 1)
    )
  }

  func flowBucketGranularity(
    in scope: MessageScope,
    statistics: MessageRangeStatistics
  ) -> FlowAnalyticsBucketGranularity {
    let start = scope.startDate ?? statistics.earliestObservedAt
    let end = scope.endDate ?? statistics.latestObservedAt
    guard let start, let end else { return .fiveMinutes }

    let span = max(0, end.timeIntervalSince(start))
    let candidates: [FlowAnalyticsBucketGranularity] = [
      .fiveMinutes, .fifteenMinutes, .sixtyMinutes, .sixHours, .twentyFourHours,
      .sevenDays, .thirtyDays, .ninetyDays, .threeHundredSixtyFiveDays,
    ]
    let targetBucketCount = 48.0
    return candidates.first {
      ceil(span / $0.duration) <= targetBucketCount
    } ?? .threeHundredSixtyFiveDays
  }

  func flowTimeBuckets(
    in scope: MessageScope,
    granularity: FlowAnalyticsBucketGranularity
  ) throws -> [FlowAnalyticsTimeBucket] {
    let fragment = try whereFragment(for: scope)
    let sql = """
      SELECT CAST(floor(m.observed_at / ?) AS INTEGER) AS bucket_index, COUNT(*)
      FROM messages AS m
      \(fragment.sql)
      GROUP BY bucket_index
      ORDER BY bucket_index ASC
      """
    let statement = try prepare(sql, operation: "flow_time_buckets")
    defer { sqlite3_finalize(statement) }
    try bind(
      [.double(granularity.duration)] + fragment.bindings,
      to: statement,
      operation: "flow_time_buckets"
    )

    var buckets: [FlowAnalyticsTimeBucket] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        let bucketIndex = sqlite3_column_int64(statement, 0)
        let startTimestamp = Double(bucketIndex) * granularity.duration
        buckets.append(FlowAnalyticsTimeBucket(
          startDate: Date(timeIntervalSince1970: startTimestamp),
          endDate: Date(timeIntervalSince1970: startTimestamp + granularity.duration),
          capturedCount: Int(sqlite3_column_int64(statement, 1))
        ))
      case SQLITE_DONE:
        return buckets
      default:
        throw queryError("flow_time_buckets")
      }
    }
  }

  func flowGroupDistribution(
    in scope: MessageScope,
    limit: Int
  ) throws -> [FlowAnalyticsGroupDistribution] {
    var fragment = try whereFragment(for: scope)
    let sql = """
      SELECT m.group_name, COUNT(*) AS captured_count
      FROM messages AS m
      \(fragment.sql)
      GROUP BY m.group_name
      ORDER BY captured_count DESC, m.group_name ASC
      LIMIT ?
      """
    fragment.bindings.append(.int64(Int64(limit)))
    let statement = try prepare(sql, operation: "flow_group_distribution")
    defer { sqlite3_finalize(statement) }
    try bind(fragment.bindings, to: statement, operation: "flow_group_distribution")

    var distribution: [FlowAnalyticsGroupDistribution] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        distribution.append(FlowAnalyticsGroupDistribution(
          group: requiredText(statement, column: 0),
          capturedCount: Int(sqlite3_column_int64(statement, 1))
        ))
      case SQLITE_DONE:
        return distribution
      default:
        throw queryError("flow_group_distribution")
      }
    }
  }

  func flowSenderDistribution(
    in scope: MessageScope,
    limit: Int
  ) throws -> [FlowAnalyticsSenderDistribution] {
    var fragment = try whereFragment(for: scope)
    let sql = """
      WITH scoped AS (
        SELECT
          CASE
            WHEN NULLIF(TRIM(m.sender_stable_id), '') IS NOT NULL
              THEN 'id:' || m.sender_stable_id
            WHEN NULLIF(TRIM(m.sender_display_name), '') IS NOT NULL
              THEN 'name:' || m.sender_display_name
            ELSE 'unknown'
          END AS sender_key,
          m.sender_display_name,
          m.sender_stable_id,
          m.observed_at,
          m.source_sequence,
          m.event_id,
          m.id
        FROM messages AS m
        \(fragment.sql)
      ), ranked AS (
        SELECT
          sender_key,
          sender_display_name,
          sender_stable_id,
          COUNT(*) OVER (PARTITION BY sender_key) AS captured_count,
          ROW_NUMBER() OVER (
            PARTITION BY sender_key
            ORDER BY
              (NULLIF(TRIM(sender_display_name), '') IS NULL) ASC,
              observed_at DESC,
              (source_sequence IS NULL) ASC,
              source_sequence DESC,
              event_id DESC,
              id DESC
          ) AS display_rank
        FROM scoped
      )
      SELECT
        sender_key,
        CASE
          WHEN NULLIF(TRIM(sender_display_name), '') IS NOT NULL
            THEN sender_display_name
          ELSE NULL
        END AS display_name,
        CASE
          WHEN NULLIF(TRIM(sender_stable_id), '') IS NOT NULL
            THEN sender_stable_id
          ELSE NULL
        END AS stable_id,
        captured_count
      FROM ranked
      WHERE display_rank = 1
      ORDER BY captured_count DESC, sender_key ASC
      LIMIT ?
      """
    fragment.bindings.append(.int64(Int64(limit)))
    let statement = try prepare(sql, operation: "flow_sender_distribution")
    defer { sqlite3_finalize(statement) }
    try bind(fragment.bindings, to: statement, operation: "flow_sender_distribution")

    var distribution: [FlowAnalyticsSenderDistribution] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        distribution.append(FlowAnalyticsSenderDistribution(
          identityKey: requiredText(statement, column: 0),
          displayName: optionalText(statement, column: 1),
          stableID: optionalText(statement, column: 2),
          capturedCount: Int(sqlite3_column_int64(statement, 3))
        ))
      case SQLITE_DONE:
        return distribution
      default:
        throw queryError("flow_sender_distribution")
      }
    }
  }

  func flowMessageTypeDistribution(
    in scope: MessageScope
  ) throws -> [FlowAnalyticsMessageTypeDistribution] {
    let fragment = try whereFragment(for: scope)
    let sql = """
      SELECT m.message_type, COUNT(*) AS captured_count
      FROM messages AS m
      \(fragment.sql)
      GROUP BY m.message_type
      ORDER BY captured_count DESC, m.message_type ASC
      """
    let statement = try prepare(sql, operation: "flow_type_distribution")
    defer { sqlite3_finalize(statement) }
    try bind(fragment.bindings, to: statement, operation: "flow_type_distribution")

    var distribution: [FlowAnalyticsMessageTypeDistribution] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        let rawValue = requiredText(statement, column: 0)
        guard let messageType = MessageKind(rawValue: rawValue) else {
          throw MessageStoreError.decodingFailed("message_type")
        }
        distribution.append(FlowAnalyticsMessageTypeDistribution(
          messageType: messageType,
          capturedCount: Int(sqlite3_column_int64(statement, 1))
        ))
      case SQLITE_DONE:
        return distribution
      default:
        throw queryError("flow_type_distribution")
      }
    }
  }

  func withReadTransaction<T>(_ body: () throws -> T) throws -> T {
    try Self.execute(database, sql: "BEGIN DEFERRED", operation: "read_transaction_begin")
    do {
      let value = try body()
      try Self.execute(database, sql: "COMMIT", operation: "read_transaction_commit")
      return value
    } catch {
      try? Self.execute(database, sql: "ROLLBACK", operation: "read_transaction_rollback")
      throw error
    }
  }

  func withTransaction<T>(_ body: () throws -> T) throws -> T {
    try Self.execute(database, sql: "BEGIN IMMEDIATE", operation: "transaction_begin")
    do {
      let value = try body()
      try Self.execute(database, sql: "COMMIT", operation: "transaction_commit")
      return value
    } catch {
      try? Self.execute(database, sql: "ROLLBACK", operation: "transaction_rollback")
      throw error
    }
  }

  func validate(_ event: MessageEvent) throws {
    _ = try normalizedRequired(event.eventID, field: "event.eventID")
    _ = try normalizedRequired(event.group, field: "event.group")
  }

  func validate(_ scope: MessageScope) throws {
    if let start = scope.startDate, let end = scope.endDate, start >= end {
      throw MessageStoreError.invalidArgument("scope.dateRange")
    }
    var cursorGroups = Set<String>()
    for cursor in scope.afterReviewCursors {
      let group = try normalizedRequired(cursor.group, field: "scope.afterReviewCursors.group")
      _ = try normalizedRequired(cursor.eventID, field: "scope.afterReviewCursors.eventID")
      guard cursorGroups.insert(group).inserted else {
        throw MessageStoreError.invalidArgument("scope.afterReviewCursors.duplicateGroup")
      }
    }
  }

  func normalizedRequired(_ value: String, field: String) throws -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw MessageStoreError.invalidArgument(field) }
    return normalized
  }

  func insertOne(_ event: MessageEvent) throws -> MessageInsertResult {
    if try messageExists(event.eventID) {
      return try updateExistingMessage(event) ? .updated : .existing
    }

    let now = Date().timeIntervalSince1970
    let group = event.group.trimmingCharacters(in: .whitespacesAndNewlines)
    let conversation = try prepare(
      """
      INSERT INTO conversations(source, group_name, created_at, updated_at, last_message_at)
      VALUES ('wechat', ?, ?, ?, ?)
      ON CONFLICT(source, group_name) DO NOTHING
      """,
      operation: "conversation_insert"
    )
    defer { sqlite3_finalize(conversation) }
    try bind(
      [.text(group), .double(now), .double(now), .double(event.observedAt.timeIntervalSince1970)],
      to: conversation,
      operation: "conversation_insert"
    )
    guard sqlite3_step(conversation) == SQLITE_DONE else {
      throw queryError("conversation_insert")
    }
    let conversationID = try conversationID(for: group)
    let attachmentsData = try encode(event.attachments, field: "attachments")

    let statement = try prepare(
      """
      INSERT INTO messages(
        event_id, conversation_id, group_name, sender_display_name, sender_stable_id,
        content, message_type, observed_at, source_sequence, attachments_json,
        attachment_count, sender_confidence, is_from_self, inserted_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(event_id) DO NOTHING
      """,
      operation: "message_insert"
    )
    defer { sqlite3_finalize(statement) }
    try bind(
      [
        .text(event.eventID), .int64(conversationID), .text(group),
        event.senderDisplayName.map(SQLiteValue.text) ?? .null,
        event.senderStableID.map(SQLiteValue.text) ?? .null,
        .text(event.content), .text(event.messageType.rawValue),
        .double(event.observedAt.timeIntervalSince1970),
        event.sourceSequence.map(SQLiteValue.int64) ?? .null,
        .blob(attachmentsData), .int64(Int64(event.attachments.count)),
        .text(event.senderConfidence.rawValue), .int64(event.isFromSelf ? 1 : 0),
        .double(now),
      ],
      to: statement,
      operation: "message_insert"
    )
    guard sqlite3_step(statement) == SQLITE_DONE else { throw queryError("message_insert") }
    guard sqlite3_changes(database) == 1 else { return .existing }

    let update = try prepare(
      """
      UPDATE conversations
      SET updated_at = ?,
        last_message_at = CASE
          WHEN last_message_at IS NULL OR last_message_at < ? THEN ?
          ELSE last_message_at
        END,
        message_count = message_count + 1
      WHERE id = ?
      """,
      operation: "conversation_update"
    )
    defer { sqlite3_finalize(update) }
    let observed = event.observedAt.timeIntervalSince1970
    try bind(
      [.double(now), .double(observed), .double(observed), .int64(conversationID)],
      to: update,
      operation: "conversation_update"
    )
    guard sqlite3_step(update) == SQLITE_DONE else { throw queryError("conversation_update") }
    return .inserted
  }

  func updateExistingMessage(_ event: MessageEvent) throws -> Bool {
    let attachmentsData = try encode(event.attachments, field: "attachments")
    let observedAt = event.observedAt.timeIntervalSince1970
    let group = event.group.trimmingCharacters(in: .whitespacesAndNewlines)
    let senderDisplayName = event.senderDisplayName.map(SQLiteValue.text) ?? .null
    let senderStableID = event.senderStableID.map(SQLiteValue.text) ?? .null
    let sourceSequence = event.sourceSequence.map(SQLiteValue.int64) ?? .null
    let isFromSelf = SQLiteValue.int64(event.isFromSelf ? 1 : 0)
    let values: [SQLiteValue] = [
      senderDisplayName, senderStableID, .text(event.content), .text(event.messageType.rawValue),
      .double(observedAt), sourceSequence, .blob(attachmentsData),
      .int64(Int64(event.attachments.count)), .text(event.senderConfidence.rawValue), isFromSelf,
    ]
    let statement = try prepare(
      """
      UPDATE messages
      SET sender_display_name = ?, sender_stable_id = ?, content = ?, message_type = ?,
        observed_at = ?, source_sequence = ?, attachments_json = ?, attachment_count = ?,
        sender_confidence = ?, is_from_self = ?, record_version = record_version + 1
      WHERE event_id = ? AND group_name = ? AND observed_at <= ? AND (
        sender_display_name IS NOT ? OR sender_stable_id IS NOT ? OR content <> ? OR
        message_type <> ? OR observed_at <> ? OR source_sequence IS NOT ? OR
        attachments_json <> ? OR attachment_count <> ? OR sender_confidence <> ? OR
        is_from_self <> ?
      )
      """,
      operation: "message_update"
    )
    defer { sqlite3_finalize(statement) }
    try bind(
      values + [.text(event.eventID), .text(group), .double(observedAt)] + values,
      to: statement,
      operation: "message_update"
    )
    guard sqlite3_step(statement) == SQLITE_DONE else { throw queryError("message_update") }
    guard sqlite3_changes(database) == 1 else { return false }

    let now = Date().timeIntervalSince1970
    let conversation = try prepare(
      """
      UPDATE conversations
      SET updated_at = ?,
        last_message_at = CASE
          WHEN last_message_at IS NULL OR last_message_at < ? THEN ?
          ELSE last_message_at
        END
      WHERE id = (SELECT conversation_id FROM messages WHERE event_id = ?)
      """,
      operation: "conversation_message_update"
    )
    defer { sqlite3_finalize(conversation) }
    try bind(
      [.double(now), .double(observedAt), .double(observedAt), .text(event.eventID)],
      to: conversation,
      operation: "conversation_message_update"
    )
    guard sqlite3_step(conversation) == SQLITE_DONE else {
      throw queryError("conversation_message_update")
    }
    return true
  }

  func messageExists(_ eventID: String) throws -> Bool {
    let statement = try prepare(
      "SELECT 1 FROM messages WHERE event_id = ? LIMIT 1",
      operation: "message_exists"
    )
    defer { sqlite3_finalize(statement) }
    try bind([.text(eventID)], to: statement, operation: "message_exists")
    return sqlite3_step(statement) == SQLITE_ROW
  }

  func conversationID(for group: String) throws -> Int64 {
    let statement = try prepare(
      "SELECT id FROM conversations WHERE source = 'wechat' AND group_name = ?",
      operation: "conversation_lookup"
    )
    defer { sqlite3_finalize(statement) }
    try bind([.text(group)], to: statement, operation: "conversation_lookup")
    guard sqlite3_step(statement) == SQLITE_ROW else { throw queryError("conversation_lookup") }
    return sqlite3_column_int64(statement, 0)
  }

  func whereFragment(for scope: MessageScope) throws -> SQLFragment {
    var result = SQLFragment()
    if !scope.groups.isEmpty {
      let groups = scope.groups.sorted()
      result.clauses.append("m.group_name IN (\(placeholders(groups.count)))")
      result.bindings.append(contentsOf: groups.map(SQLiteValue.text))
    }
    if let start = scope.startDate {
      result.clauses.append("m.observed_at >= ?")
      result.bindings.append(.double(start.timeIntervalSince1970))
    }
    if let end = scope.endDate {
      result.clauses.append("m.observed_at < ?")
      result.bindings.append(.double(end.timeIntervalSince1970))
    }
    if !scope.messageTypes.isEmpty {
      let types = scope.messageTypes.map(\.rawValue).sorted()
      result.clauses.append("m.message_type IN (\(placeholders(types.count)))")
      result.bindings.append(contentsOf: types.map(SQLiteValue.text))
    }
    if !scope.senders.isEmpty {
      let senders = scope.senders.sorted()
      let slots = placeholders(senders.count)
      result.clauses.append(
        "(m.sender_display_name IN (\(slots)) OR m.sender_stable_id IN (\(slots)))"
      )
      result.bindings.append(contentsOf: senders.map(SQLiteValue.text))
      result.bindings.append(contentsOf: senders.map(SQLiteValue.text))
    }
    if !scope.tagIDs.isEmpty {
      let tags = scope.tagIDs.sorted()
      result.clauses.append(
        """
        EXISTS (
          SELECT 1 FROM message_tags AS scoped_tags
          WHERE scoped_tags.message_id = m.id
            AND scoped_tags.tag_id IN (\(placeholders(tags.count)))
        )
        """
      )
      result.bindings.append(contentsOf: tags.map(SQLiteValue.text))
    }
    if !scope.excludedTagIDs.isEmpty {
      let tags = scope.excludedTagIDs.sorted()
      result.clauses.append(
        """
        NOT EXISTS (
          SELECT 1 FROM message_tags AS excluded_scope_tags
          WHERE excluded_scope_tags.message_id = m.id
            AND excluded_scope_tags.tag_id IN (\(placeholders(tags.count)))
        )
        """
      )
      result.bindings.append(contentsOf: tags.map(SQLiteValue.text))
    }
    appendSearchableTerms(scope.includeAnyTerms, negated: false, to: &result)
    appendSearchableTerms(scope.excludeAnyTerms, negated: true, to: &result)
    if !scope.contentContainsAnyTerms.isEmpty {
      let terms = normalizedScopeTerms(scope.contentContainsAnyTerms)
      if !terms.isEmpty {
        let predicates = terms.map { _ in "m.content LIKE ? ESCAPE '\\' COLLATE NOCASE" }
        result.clauses.append("(" + predicates.joined(separator: " OR ") + ")")
        result.bindings.append(contentsOf: terms.map {
          .text("%\(escapedLike($0))%")
        })
      }
    }
    if scope.requiresKnownSender {
      result.clauses.append(
        """
        (NULLIF(TRIM(m.sender_stable_id), '') IS NOT NULL
          OR NULLIF(TRIM(m.sender_display_name), '') IS NOT NULL)
        """
      )
    }
    if let anyMatch = scope.anyMatch {
      appendAnyMatchScope(anyMatch, to: &result)
    }
    appendReviewCursorScope(scope, to: &result)
    if let rawSearch = scope.searchText?.trimmingCharacters(in: .whitespacesAndNewlines),
      !rawSearch.isEmpty
    {
      if capabilities.fullTextSearchAvailable, shouldUseFTS(rawSearch) {
        result.clauses.append(
          "m.id IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?)"
        )
        result.bindings.append(.text(ftsQuery(rawSearch)))
      } else {
        let pattern = "%\(escapedLike(rawSearch))%"
        result.clauses.append(
          """
          (m.content LIKE ? ESCAPE '\\' COLLATE NOCASE
            OR m.group_name LIKE ? ESCAPE '\\' COLLATE NOCASE
            OR m.sender_display_name LIKE ? ESCAPE '\\' COLLATE NOCASE)
          """
        )
        result.bindings.append(contentsOf: [.text(pattern), .text(pattern), .text(pattern)])
      }
    }
    return result
  }

  func normalizedScopeTerms(_ terms: Set<String>) -> [String] {
    terms
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .sorted()
  }

  func normalizedScopeTagIDs(_ tagIDs: Set<String>) -> Set<String> {
    Set(tagIDs.compactMap { rawValue in
      let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty ? nil : value
    })
  }

  func normalizedScopeAnyMatch(
    _ anyMatch: MessageScopeAnyMatch?
  ) -> MessageScopeAnyMatch? {
    guard let anyMatch else { return nil }
    let tagIDs = normalizedScopeTagIDs(anyMatch.tagIDs)
    let terms = Set(normalizedScopeTerms(anyMatch.terms))
    guard !tagIDs.isEmpty || !terms.isEmpty else { return nil }
    return MessageScopeAnyMatch(tagIDs: tagIDs, terms: terms)
  }

  func appendAnyMatchScope(
    _ anyMatch: MessageScopeAnyMatch,
    to fragment: inout SQLFragment
  ) {
    var alternatives: [String] = []
    var bindings: [SQLiteValue] = []
    let tags = normalizedScopeTagIDs(anyMatch.tagIDs).sorted()
    if !tags.isEmpty {
      alternatives.append(
        """
        EXISTS (
          SELECT 1 FROM message_tags AS any_scope_tags
          WHERE any_scope_tags.message_id = m.id
            AND any_scope_tags.tag_id IN (\(placeholders(tags.count)))
        )
        """
      )
      bindings.append(contentsOf: tags.map(SQLiteValue.text))
    }
    let terms = normalizedScopeTerms(anyMatch.terms)
    if !terms.isEmpty {
      alternatives.append(searchableTermsClause(count: terms.count))
      for term in terms {
        let pattern = SQLiteValue.text("%\(escapedLike(term))%")
        bindings.append(contentsOf: [pattern, pattern, pattern])
      }
    }
    guard !alternatives.isEmpty else { return }
    fragment.clauses.append("(" + alternatives.joined(separator: " OR ") + ")")
    fragment.bindings.append(contentsOf: bindings)
  }

  func searchableTermsClause(count: Int) -> String {
    let one = """
      (m.content LIKE ? ESCAPE '\\' COLLATE NOCASE
        OR m.group_name LIKE ? ESCAPE '\\' COLLATE NOCASE
        OR m.sender_display_name LIKE ? ESCAPE '\\' COLLATE NOCASE)
      """
    return "(" + Array(repeating: one, count: count).joined(separator: " OR ") + ")"
  }

  func appendSearchableTerms(
    _ rawTerms: Set<String>,
    negated: Bool,
    to fragment: inout SQLFragment
  ) {
    let terms = normalizedScopeTerms(rawTerms)
    guard !terms.isEmpty else { return }
    let clause = searchableTermsClause(count: terms.count)
    fragment.clauses.append(negated ? "NOT \(clause)" : clause)
    for term in terms {
      let pattern = SQLiteValue.text("%\(escapedLike(term))%")
      fragment.bindings.append(contentsOf: [pattern, pattern, pattern])
    }
  }

  func appendReviewCursorScope(_ scope: MessageScope, to fragment: inout SQLFragment) {
    let cursors = scope.afterReviewCursors.sorted { $0.group < $1.group }
    guard !cursors.isEmpty else { return }

    var alternatives: [String] = []
    var bindings: [SQLiteValue] = []
    let cursorGroups = Set(cursors.map(\.group))
    let groupsWithoutCursor = scope.groups.subtracting(cursorGroups).sorted()
    if !groupsWithoutCursor.isEmpty {
      alternatives.append("m.group_name IN (\(placeholders(groupsWithoutCursor.count)))")
      bindings.append(contentsOf: groupsWithoutCursor.map(SQLiteValue.text))
    } else if scope.groups.isEmpty {
      let orderedCursorGroups = cursorGroups.sorted()
      alternatives.append("m.group_name NOT IN (\(placeholders(orderedCursorGroups.count)))")
      bindings.append(contentsOf: orderedCursorGroups.map(SQLiteValue.text))
    }

    for cursor in cursors {
      let observed = SQLiteValue.double(cursor.observedAt.timeIntervalSince1970)
      let orderingClause: String
      var orderingBindings: [SQLiteValue]
      if let sequence = cursor.sourceSequence {
        orderingClause = """
          (m.source_sequence IS NULL
            OR (m.source_sequence IS NOT NULL AND (
              m.source_sequence > ?
              OR (m.source_sequence = ? AND m.event_id > ?)
            )))
          """
        orderingBindings = [.int64(sequence), .int64(sequence), .text(cursor.eventID)]
      } else {
        orderingClause = "(m.source_sequence IS NULL AND m.event_id > ?)"
        orderingBindings = [.text(cursor.eventID)]
      }
      alternatives.append(
        """
        (m.group_name = ? AND (
          m.observed_at > ?
          OR (m.observed_at = ? AND \(orderingClause))
        ))
        """
      )
      bindings.append(contentsOf: [.text(cursor.group), observed, observed])
      bindings.append(contentsOf: orderingBindings)
    }

    fragment.clauses.append("(" + alternatives.joined(separator: " OR ") + ")")
    fragment.bindings.append(contentsOf: bindings)
  }

  func appendCursor(
    _ cursor: MessagePageCursor,
    order: MessageSortOrder,
    to fragment: inout SQLFragment
  ) {
    let dateComparator = order == .newestFirst ? "<" : ">"
    let sequenceComparator = dateComparator
    let idComparator = dateComparator
    let missing = cursor.sourceSequence == nil ? Int64(1) : Int64(0)
    let sourceClause: String
    var innerBindings: [SQLiteValue]

    if let sequence = cursor.sourceSequence {
      sourceClause = """
        m.source_sequence \(sequenceComparator) ?
        OR (m.source_sequence = ? AND (
          m.event_id \(idComparator) ?
          OR (m.event_id = ? AND m.id \(idComparator) ?)
        ))
        """
      innerBindings = [
        .int64(sequence), .int64(sequence), .text(cursor.eventID),
        .text(cursor.eventID), .int64(cursor.storageID),
      ]
    } else {
      sourceClause = """
        m.event_id \(idComparator) ?
        OR (m.event_id = ? AND m.id \(idComparator) ?)
        """
      innerBindings = [.text(cursor.eventID), .text(cursor.eventID), .int64(cursor.storageID)]
    }

    fragment.clauses.append(
      """
      (
        m.observed_at \(dateComparator) ?
        OR (m.observed_at = ? AND (
          (m.source_sequence IS NULL) > ?
          OR ((m.source_sequence IS NULL) = ? AND (\(sourceClause)))
        ))
      )
      """
    )
    fragment.bindings.append(.double(cursor.observedAt.timeIntervalSince1970))
    fragment.bindings.append(.double(cursor.observedAt.timeIntervalSince1970))
    fragment.bindings.append(.int64(missing))
    fragment.bindings.append(.int64(missing))
    fragment.bindings.append(contentsOf: innerBindings)
  }

  func readMessages(sql: String, bindings: [SQLiteValue]) throws -> [StoredMessage] {
    let statement = try prepare(sql, operation: "read_messages")
    defer { sqlite3_finalize(statement) }
    try bind(bindings, to: statement, operation: "read_messages")
    var rows: [StoredMessage] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW: rows.append(try decodeStoredMessage(statement))
      case SQLITE_DONE: return rows
      default: throw queryError("read_messages")
      }
    }
  }

  func decodeStoredMessage(_ statement: OpaquePointer) throws -> StoredMessage {
    let attachmentsData = requiredData(statement, column: 9)
    let attachments: [MessageAttachment] = try decode(
      [MessageAttachment].self,
      from: attachmentsData,
      field: "attachments"
    )
    let event = MessageEvent(
      eventID: requiredText(statement, column: 1),
      group: requiredText(statement, column: 2),
      senderDisplayName: optionalText(statement, column: 3),
      senderStableID: optionalText(statement, column: 4),
      content: requiredText(statement, column: 5),
      messageType: MessageKind(rawValue: requiredText(statement, column: 6)) ?? .unknown,
      observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
      sourceSequence: optionalInt64(statement, column: 8),
      attachments: attachments,
      senderConfidence: SenderConfidence(rawValue: requiredText(statement, column: 10))
        ?? .unavailable,
      isFromSelf: sqlite3_column_int(statement, 11) != 0
    )
    return StoredMessage(
      storageID: sqlite3_column_int64(statement, 0),
      event: event,
      insertedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12))
    )
  }

  func attachingTags(to messages: [StoredMessage]) throws -> [StoredMessage] {
    guard !messages.isEmpty else { return [] }
    var tagsByMessageID: [Int64: [String]] = [:]
    for chunk in messages.map(\.storageID).chunked(maximumSize: 400) {
      let statement = try prepare(
        """
        SELECT message_id, tag_id
        FROM message_tags
        WHERE message_id IN (\(placeholders(chunk.count)))
        ORDER BY message_id, tag_id
        """,
        operation: "attach_tags"
      )
      defer { sqlite3_finalize(statement) }
      try bind(chunk.map(SQLiteValue.int64), to: statement, operation: "attach_tags")
      while true {
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
          tagsByMessageID[sqlite3_column_int64(statement, 0), default: []]
            .append(requiredText(statement, column: 1))
        case SQLITE_DONE:
          break
        default:
          throw queryError("attach_tags")
        }
        if sqlite3_data_count(statement) == 0 { break }
      }
    }
    return messages.map {
      StoredMessage(
        storageID: $0.storageID,
        event: $0.event,
        insertedAt: $0.insertedAt,
        tagIDs: tagsByMessageID[$0.storageID] ?? []
      )
    }
  }

  func tagExists(_ id: String) throws -> Bool {
    let statement = try prepare("SELECT 1 FROM tags WHERE id = ?", operation: "tag_exists")
    defer { sqlite3_finalize(statement) }
    try bind([.text(id)], to: statement, operation: "tag_exists")
    return sqlite3_step(statement) == SQLITE_ROW
  }

  func decodeTag(_ statement: OpaquePointer) -> MessageTag {
    MessageTag(
      id: requiredText(statement, column: 0),
      name: requiredText(statement, column: 1),
      colorHex: optionalText(statement, column: 2),
      createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
    )
  }

  func frozenRangeExists(_ id: String) throws -> Bool {
    let statement = try prepare(
      "SELECT 1 FROM frozen_message_ranges WHERE id = ?",
      operation: "frozen_range_exists"
    )
    defer { sqlite3_finalize(statement) }
    try bind([.text(id)], to: statement, operation: "frozen_range_exists")
    return sqlite3_step(statement) == SQLITE_ROW
  }

  func frozenEventIDs(id: String) throws -> [String] {
    let statement = try prepare(
      """
      SELECT event_id FROM frozen_message_items
      WHERE range_id = ? ORDER BY ordinal ASC
      """,
      operation: "frozen_event_ids"
    )
    defer { sqlite3_finalize(statement) }
    try bind([.text(id)], to: statement, operation: "frozen_event_ids")
    var ids: [String] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW: ids.append(requiredText(statement, column: 0))
      case SQLITE_DONE: return ids
      default: throw queryError("frozen_event_ids")
      }
    }
  }

  func eventTimestamp(eventID: String) throws -> Date {
    let statement = try prepare(
      "SELECT observed_at FROM messages WHERE event_id = ?",
      operation: "event_timestamp"
    )
    defer { sqlite3_finalize(statement) }
    try bind([.text(eventID)], to: statement, operation: "event_timestamp")
    guard sqlite3_step(statement) == SQLITE_ROW else { throw MessageStoreError.messageNotFound }
    return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
  }

  func eventSourceSequence(eventID: String) throws -> Int64? {
    let statement = try prepare(
      "SELECT source_sequence FROM messages WHERE event_id = ?",
      operation: "event_sequence"
    )
    defer { sqlite3_finalize(statement) }
    try bind([.text(eventID)], to: statement, operation: "event_sequence")
    guard sqlite3_step(statement) == SQLITE_ROW else { throw MessageStoreError.messageNotFound }
    return optionalInt64(statement, column: 0)
  }

  func encode<T: Encodable>(_ value: T, field: String) throws -> Data {
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .millisecondsSince1970
      return try encoder.encode(value)
    } catch {
      throw MessageStoreError.decodingFailed(field)
    }
  }

  func decode<T: Decodable>(_ type: T.Type, from data: Data, field: String) throws -> T {
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .millisecondsSince1970
      return try decoder.decode(type, from: data)
    } catch {
      throw MessageStoreError.decodingFailed(field)
    }
  }

  func requiredText(_ statement: OpaquePointer, column: Int32) -> String {
    sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
  }

  func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return requiredText(statement, column: column)
  }

  func optionalInt64(_ statement: OpaquePointer, column: Int32) -> Int64? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return sqlite3_column_int64(statement, column)
  }

  func optionalDate(_ statement: OpaquePointer, column: Int32) -> Date? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
  }

  func requiredData(_ statement: OpaquePointer, column: Int32) -> Data {
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
    return Data(bytes: bytes, count: count)
  }

  func placeholders(_ count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
  }

  func orderedUnique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap {
      let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty, seen.insert(value).inserted else { return nil }
      return value
    }
  }

  func escapedLike(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
  }

  func shouldUseFTS(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy { $0.isASCII }
  }

  func ftsQuery(_ value: String) -> String {
    let tokens = value.split(whereSeparator: { $0.isWhitespace })
    return tokens.map { token in
      "\"\(token.replacingOccurrences(of: "\"", with: "\"\""))\""
    }.joined(separator: " AND ")
  }
}

private extension Array {
  func chunked(maximumSize: Int) -> [[Element]] {
    guard !isEmpty else { return [] }
    var chunks: [[Element]] = []
    var start = 0
    while start < count {
      let end = Swift.min(start + maximumSize, count)
      chunks.append(Array(self[start..<end]))
      start = end
    }
    return chunks
  }
}
