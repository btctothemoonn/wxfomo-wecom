import Darwin
import Foundation
import SQLite3

@_silgen_name("flock")
private func workspaceFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

private final class WorkspaceDatabaseLock: @unchecked Sendable {
  private var descriptor: Int32

  init(databaseURL: URL) throws {
    let lockPath = databaseURL.path + ".lock"
    let opened = open(
      lockPath,
      O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard opened >= 0 else {
      throw WorkspaceStoreError.databaseLockFailed(lockPath)
    }

    var information = stat()
    guard fstat(opened, &information) == 0,
      (information.st_mode & S_IFMT) == S_IFREG,
      information.st_uid == geteuid(),
      fchmod(opened, S_IRUSR | S_IWUSR) == 0
    else {
      close(opened)
      throw WorkspaceStoreError.databaseLockFailed(lockPath)
    }
    guard workspaceFlock(opened, LOCK_EX | LOCK_NB) == 0 else {
      let lockError = errno
      close(opened)
      if lockError == EWOULDBLOCK || lockError == EAGAIN {
        throw WorkspaceStoreError.databaseAlreadyInUse(databaseURL.path)
      }
      throw WorkspaceStoreError.databaseLockFailed(lockPath)
    }
    descriptor = opened
  }

  func release() {
    guard descriptor >= 0 else { return }
    _ = workspaceFlock(descriptor, LOCK_UN)
    close(descriptor)
    descriptor = -1
  }

  deinit {
    release()
  }
}

public actor WorkspaceStore {
  public static let currentSchemaVersion = 6
  public static let crossGroupAddressWindow: TimeInterval = 24 * 60 * 60
  public static let defaultDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/wxFomo", isDirectory: true)
    .appendingPathComponent("workspace.sqlite3", isDirectory: false)

  public nonisolated let databaseURL: URL
  public nonisolated let capabilities: WorkspaceStoreCapabilities

  private let database: OpaquePointer
  private let databaseLock: WorkspaceDatabaseLock

  public init(databaseURL: URL = WorkspaceStore.defaultDatabaseURL) throws {
    try Self.prepareParentDirectory(for: databaseURL)
    let acquiredLock = try WorkspaceDatabaseLock(databaseURL: databaseURL)

    var openedDatabase: OpaquePointer?
    let result = sqlite3_open_v2(
      databaseURL.path,
      &openedDatabase,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard result == SQLITE_OK, let openedDatabase else {
      if let openedDatabase { sqlite3_close(openedDatabase) }
      throw WorkspaceStoreError.cannotOpenDatabase(databaseURL.path)
    }

    do {
      sqlite3_extended_result_codes(openedDatabase, 1)
      guard sqlite3_busy_timeout(openedDatabase, 5_000) == SQLITE_OK else {
        throw WorkspaceStoreError.configurationFailed("busy_timeout")
      }
      try Self.execute(openedDatabase, sql: "PRAGMA foreign_keys = ON", operation: "foreign_keys")
      guard try Self.integerPragma(openedDatabase, name: "foreign_keys") == 1 else {
        throw WorkspaceStoreError.configurationFailed("foreign_keys")
      }
      let journalMode = try Self.setJournalModeToWAL(openedDatabase)
      try Self.execute(openedDatabase, sql: "PRAGMA synchronous = NORMAL", operation: "synchronous")
      try Self.execute(
        openedDatabase,
        sql: "PRAGMA wal_autocheckpoint = 1000",
        operation: "wal_autocheckpoint"
      )
      let schemaVersion = try Self.migrate(openedDatabase)
      let recoveredJobCount = try Self.recoverRunningJobs(openedDatabase, now: Date())

      self.databaseURL = databaseURL
      database = openedDatabase
      databaseLock = acquiredLock
      capabilities = WorkspaceStoreCapabilities(
        schemaVersion: schemaVersion,
        journalMode: journalMode,
        recoveredRunningJobCount: recoveredJobCount
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
    databaseLock.release()
  }
}

// MARK: - DexScreener chain resolution cache

public extension WorkspaceStore {
  func dexScreenerChainResolution(
    address rawAddress: String,
    now: Date = Date(),
    maxAge: TimeInterval = DexScreenerChainResolver.persistentCacheTTL
  ) throws -> DexScreenerChainResolution? {
    let address = try normalizedEVMAddress(rawAddress)
    guard maxAge > 0, maxAge.isFinite else {
      throw WorkspaceStoreError.invalidArgument("dexChainCache.maxAge")
    }
    let statement = try prepare(
      """
      SELECT resolution_json
      FROM dex_chain_resolution_cache
      WHERE normalized_address = ? AND resolved_at >= ?
      """,
      operation: "dex_chain_cache_read"
    )
    defer { sqlite3_finalize(statement) }
    try bind(
      [.text(address), .double(now.addingTimeInterval(-maxAge).timeIntervalSince1970)],
      to: statement,
      operation: "dex_chain_cache_read"
    )
    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      let resolution: DexScreenerChainResolution
      do {
        resolution = try Self.makeJSONDecoder().decode(
          DexScreenerChainResolution.self,
          from: requiredData(statement, column: 0)
        )
      } catch {
        throw WorkspaceStoreError.queryFailed(
          operation: "dex_chain_cache_decode",
          reason: Self.codingFailureReason(error)
        )
      }
      guard resolution.address == address,
        let chain = resolution.selectedChain,
        chain != .sol
      else {
        throw WorkspaceStoreError.queryFailed(
          operation: "dex_chain_cache_validate",
          reason: "invalid_cached_resolution"
        )
      }
      try executePrepared(
        "UPDATE dex_chain_resolution_cache SET last_accessed_at = ? WHERE normalized_address = ?",
        values: [.double(now.timeIntervalSince1970), .text(address)],
        operation: "dex_chain_cache_touch"
      )
      return resolution.markingSource(.persistentCache)
    case SQLITE_DONE:
      return nil
    default:
      throw queryError("dex_chain_cache_read")
    }
  }

  @discardableResult
  func saveDexScreenerChainResolution(
    _ resolution: DexScreenerChainResolution,
    now: Date = Date()
  ) throws -> DexScreenerChainResolution {
    let address = try normalizedEVMAddress(resolution.address)
    guard let chain = resolution.selectedChain, chain != .sol else {
      throw WorkspaceStoreError.invalidArgument("dexChainCache.resolution")
    }
    let stored = DexScreenerChainResolution(
      address: address,
      selectedChain: chain,
      candidates: resolution.candidates,
      resolvedAt: resolution.resolvedAt,
      source: .network
    )
    let data: Data
    do {
      data = try Self.makeJSONEncoder().encode(stored)
    } catch {
      throw WorkspaceStoreError.invalidArgument("dexChainCache.json")
    }
    try withTransaction {
      try executePrepared(
        """
        INSERT INTO dex_chain_resolution_cache(
          normalized_address, chain, resolution_json, resolved_at, last_accessed_at
        ) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(normalized_address) DO UPDATE SET
          chain = excluded.chain,
          resolution_json = excluded.resolution_json,
          resolved_at = excluded.resolved_at,
          last_accessed_at = excluded.last_accessed_at
        """,
        values: [
          .text(address), .text(chain.rawValue), .blob(data),
          .double(stored.resolvedAt.timeIntervalSince1970),
          .double(now.timeIntervalSince1970),
        ],
        operation: "dex_chain_cache_save"
      )
      try executePrepared(
        """
        DELETE FROM dex_chain_resolution_cache
        WHERE normalized_address NOT IN (
          SELECT normalized_address FROM dex_chain_resolution_cache
          ORDER BY last_accessed_at DESC LIMIT 1000
        )
        """,
        values: [],
        operation: "dex_chain_cache_prune"
      )
    }
    return stored
  }
}

// MARK: - Provider configurations

public extension WorkspaceStore {
  /// Persists only `AIProviderConfiguration`. API keys remain in `AICredentialStoring`.
  @discardableResult
  func saveProviderConfiguration(
    _ configuration: AIProviderConfiguration,
    makeDefault: Bool = false,
    now: Date = Date()
  ) throws -> AIProviderConfiguration {
    do {
      try configuration.validate()
    } catch {
      throw WorkspaceStoreError.invalidProviderConfiguration(
        configurationID: configuration.configurationID,
        reason: String(describing: error)
      )
    }
    let identifier = try normalizedRequired(
      configuration.configurationID,
      field: "provider.configurationID"
    )
    guard identifier == configuration.configurationID else {
      throw WorkspaceStoreError.invalidProviderConfiguration(
        configurationID: configuration.configurationID,
        reason: "identifier_has_surrounding_whitespace"
      )
    }
    let encoded = try encodeProviderConfiguration(configuration)

    try withTransaction {
      if makeDefault {
        try executePrepared(
          "UPDATE ai_provider_configurations SET is_default = 0 WHERE is_default = 1",
          values: [],
          operation: "provider_clear_default"
        )
      }
      try executePrepared(
        """
        INSERT INTO ai_provider_configurations(
          configuration_id, configuration_json, is_default, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(configuration_id) DO UPDATE SET
          configuration_json = excluded.configuration_json,
          is_default = CASE
            WHEN excluded.is_default = 1 THEN 1
            ELSE ai_provider_configurations.is_default
          END,
          updated_at = excluded.updated_at
        """,
        values: [
          .text(identifier), .blob(encoded), .int64(makeDefault ? 1 : 0),
          .double(now.timeIntervalSince1970), .double(now.timeIntervalSince1970),
        ],
        operation: "provider_save"
      )
    }
    return configuration
  }

  func providerConfiguration(id: String) throws -> AIProviderConfiguration? {
    let identifier = try normalizedRequired(id, field: "provider.id")
    let statement = try prepare(
      """
      SELECT configuration_json
      FROM ai_provider_configurations
      WHERE configuration_id = ?
      """,
      operation: "provider_read"
    )
    defer { sqlite3_finalize(statement) }
    try bind([.text(identifier)], to: statement, operation: "provider_read")
    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      return try decodeProviderConfiguration(
        requiredData(statement, column: 0),
        expectedID: identifier
      )
    case SQLITE_DONE:
      return nil
    default:
      throw queryError("provider_read")
    }
  }

  func providerConfigurations() throws -> [AIProviderConfiguration] {
    let statement = try prepare(
      """
      SELECT configuration_id, configuration_json
      FROM ai_provider_configurations
      ORDER BY is_default DESC, created_at ASC, configuration_id ASC
      """,
      operation: "provider_list"
    )
    defer { sqlite3_finalize(statement) }
    var configurations: [AIProviderConfiguration] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        let identifier = requiredText(statement, column: 0)
        configurations.append(
          try decodeProviderConfiguration(
            requiredData(statement, column: 1),
            expectedID: identifier
          )
        )
      case SQLITE_DONE:
        return configurations
      default:
        throw queryError("provider_list")
      }
    }
  }

  func defaultProviderConfiguration() throws -> AIProviderConfiguration? {
    let statement = try prepare(
      """
      SELECT configuration_id, configuration_json
      FROM ai_provider_configurations
      WHERE is_default = 1
      LIMIT 1
      """,
      operation: "provider_default"
    )
    defer { sqlite3_finalize(statement) }
    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      let identifier = requiredText(statement, column: 0)
      return try decodeProviderConfiguration(
        requiredData(statement, column: 1),
        expectedID: identifier
      )
    case SQLITE_DONE:
      return nil
    default:
      throw queryError("provider_default")
    }
  }

  func setDefaultProviderConfiguration(id: String?) throws {
    let identifier = try id.map { try normalizedRequired($0, field: "provider.id") }
    try withTransaction {
      if let identifier {
        guard try providerExists(identifier) else {
          throw WorkspaceStoreError.providerConfigurationNotFound(identifier)
        }
      }
      try executePrepared(
        "UPDATE ai_provider_configurations SET is_default = 0 WHERE is_default = 1",
        values: [],
        operation: "provider_clear_default"
      )
      if let identifier {
        try executePrepared(
          "UPDATE ai_provider_configurations SET is_default = 1 WHERE configuration_id = ?",
          values: [.text(identifier)],
          operation: "provider_set_default"
        )
      }
    }
  }

  func deleteProviderConfiguration(id: String) throws {
    let identifier = try normalizedRequired(id, field: "provider.id")
    try withTransaction {
      guard try providerExists(identifier) else {
        throw WorkspaceStoreError.providerConfigurationNotFound(identifier)
      }
      try executePrepared(
        "DELETE FROM ai_provider_configurations WHERE configuration_id = ?",
        values: [.text(identifier)],
        operation: "provider_delete"
      )
    }
  }
}

// MARK: - CA signal enrichment and watch pool

public extension WorkspaceStore {
  @discardableResult
  func saveCAWatchPoolConfiguration(
    _ configuration: CAWatchPoolConfiguration,
    now: Date = Date()
  ) throws -> CAWatchPoolConfiguration {
    let normalized = configuration.normalized
    let data: Data
    do {
      data = try Self.makeJSONEncoder().encode(normalized)
    } catch {
      throw WorkspaceStoreError.invalidArgument("caWatchPool.configuration")
    }
    try executePrepared(
      """
      INSERT INTO ca_watch_pool_configuration(singleton_id, configuration_json, updated_at)
      VALUES (1, ?, ?)
      ON CONFLICT(singleton_id) DO UPDATE SET
        configuration_json = excluded.configuration_json,
        updated_at = excluded.updated_at
      """,
      values: [.blob(data), .double(now.timeIntervalSince1970)],
      operation: "ca_pool_configuration_save"
    )
    return normalized
  }

  func caWatchPoolConfiguration() throws -> CAWatchPoolConfiguration? {
    let statement = try prepare(
      "SELECT configuration_json FROM ca_watch_pool_configuration WHERE singleton_id = 1",
      operation: "ca_pool_configuration_read"
    )
    defer { sqlite3_finalize(statement) }
    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      do {
        return try Self.makeJSONDecoder()
          .decode(CAWatchPoolConfiguration.self, from: requiredData(statement, column: 0))
          .normalized
      } catch {
        throw WorkspaceStoreError.queryFailed(
          operation: "ca_pool_configuration_decode",
          reason: Self.codingFailureReason(error)
        )
      }
    case SQLITE_DONE:
      return nil
    default:
      throw queryError("ca_pool_configuration_read")
    }
  }

  @discardableResult
  func saveCAWatchPoolItem(_ item: CAWatchPoolItem) throws -> CAWatchPoolItem {
    let address = try normalizedRequired(
      item.normalizedAddress,
      field: "caWatchPoolItem.normalizedAddress"
    )
    let network = item.network ?? item.chain?.cryptoAddressNetwork
      ?? (item.family == .solana ? .solana : .evm)
    guard address == item.normalizedAddress, item.mentionCount >= 1 else {
      throw WorkspaceStoreError.invalidArgument("caWatchPoolItem")
    }
    var normalizedItem = item
    normalizedItem.network = network
    let data: Data
    do {
      data = try Self.makeJSONEncoder().encode(normalizedItem)
    } catch {
      throw WorkspaceStoreError.invalidArgument("caWatchPoolItem.json")
    }
    try executePrepared(
      """
      INSERT INTO ca_watch_pool_items(
        family, network, normalized_address, item_json, state, is_pinned, latest_seen_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(family, network, normalized_address) DO UPDATE SET
        item_json = excluded.item_json,
        state = excluded.state,
        is_pinned = excluded.is_pinned,
        latest_seen_at = excluded.latest_seen_at,
        updated_at = excluded.updated_at
      """,
      values: [
        .text(item.family.rawValue), .text(network.rawValue), .text(address), .blob(data), .text(item.state.rawValue),
        .int64(item.isPinned ? 1 : 0), .double(item.latestSeenAt.timeIntervalSince1970),
        .double(item.updatedAt.timeIntervalSince1970),
      ],
      operation: "ca_pool_item_save"
    )
    return normalizedItem
  }

  /// Removes one persisted pool row when an unresolved EVM record is merged
  /// into the same address after chain resolution.
  func deleteCAWatchPoolItem(
    family: CryptoAddressFamily,
    network: CryptoAddressNetwork,
    normalizedAddress rawAddress: String
  ) throws {
    let address = try normalizedRequired(rawAddress, field: "caWatchPoolItem.normalizedAddress")
    try executePrepared(
      """
      DELETE FROM ca_watch_pool_items
      WHERE family = ? AND network = ? AND normalized_address = ?
      """,
      values: [.text(family.rawValue), .text(network.rawValue), .text(address)],
      operation: "ca_pool_item_delete"
    )
  }

  func caWatchPoolItems(
    states: Set<CAWatchPoolItemState> = [],
    limit: Int = 100
  ) throws -> [CAWatchPoolItem] {
    guard (1...500).contains(limit) else {
      throw WorkspaceStoreError.invalidArgument("caWatchPoolItem.limit")
    }
    let orderedStates = states.sorted { $0.rawValue < $1.rawValue }
    let clause = orderedStates.isEmpty
      ? ""
      : "WHERE state IN (\(Self.placeholders(count: orderedStates.count)))"
    var values = orderedStates.map { SQLiteValue.text($0.rawValue) }
    values.append(.int64(Int64(limit)))
    let statement = try prepare(
      """
      SELECT item_json FROM ca_watch_pool_items
      \(clause)
      ORDER BY state = 'removed' ASC, is_pinned DESC, latest_seen_at DESC
      LIMIT ?
      """,
      operation: "ca_pool_item_list"
    )
    defer { sqlite3_finalize(statement) }
    try bind(values, to: statement, operation: "ca_pool_item_list")
    var items: [CAWatchPoolItem] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        do {
          items.append(
            try Self.makeJSONDecoder().decode(
              CAWatchPoolItem.self,
              from: requiredData(statement, column: 0)
            )
          )
        } catch {
          throw WorkspaceStoreError.queryFailed(
            operation: "ca_pool_item_decode",
            reason: Self.codingFailureReason(error)
          )
        }
      case SQLITE_DONE:
        return items
      default:
        throw queryError("ca_pool_item_list")
      }
    }
  }

  @discardableResult
  func saveCASignalEnrichment(_ enrichment: CASignalEnrichment) throws
    -> CASignalEnrichment
  {
    let eventID = try normalizedRequired(enrichment.eventID, field: "caSignal.eventID")
    let address = try normalizedRequired(
      enrichment.normalizedAddress,
      field: "caSignal.normalizedAddress"
    )
    let network = enrichment.network ?? (enrichment.family == .solana ? .solana : .evm)
    guard eventID == enrichment.eventID,
      address == enrichment.normalizedAddress,
      enrichment.attemptCount >= 0
    else {
      throw WorkspaceStoreError.invalidArgument("caSignal")
    }
    let data: Data
    do {
      data = try Self.makeJSONEncoder().encode(enrichment)
    } catch {
      throw WorkspaceStoreError.invalidArgument("caSignal.json")
    }
    try executePrepared(
      """
      INSERT INTO ca_signal_enrichments(
        event_id, family, network, normalized_address, enrichment_json, state, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(event_id, family, network, normalized_address) DO UPDATE SET
        enrichment_json = excluded.enrichment_json,
        state = excluded.state,
        updated_at = excluded.updated_at
      """,
      values: [
        .text(eventID), .text(enrichment.family.rawValue), .text(network.rawValue), .text(address), .blob(data),
        .text(enrichment.state.rawValue), .double(enrichment.createdAt.timeIntervalSince1970),
        .double(enrichment.updatedAt.timeIntervalSince1970),
      ],
      operation: "ca_signal_save"
    )
    return enrichment
  }

  func caSignalEnrichments(eventIDs: [String]) throws -> [CASignalEnrichment] {
    let eventIDs = Array(Set(eventIDs)).sorted()
    guard !eventIDs.isEmpty else { return [] }
    guard eventIDs.count <= 500 else {
      throw WorkspaceStoreError.invalidArgument("caSignal.eventIDs")
    }
    let statement = try prepare(
      """
      SELECT enrichment_json FROM ca_signal_enrichments
      WHERE event_id IN (\(Self.placeholders(count: eventIDs.count)))
      ORDER BY updated_at DESC
      """,
      operation: "ca_signal_events"
    )
    defer { sqlite3_finalize(statement) }
    try bind(eventIDs.map(SQLiteValue.text), to: statement, operation: "ca_signal_events")
    return try decodeCASignalEnrichments(statement, operation: "ca_signal_events")
  }

  func caSignalEnrichments(
    states: Set<CASignalEnrichmentState>,
    limit: Int = 500
  ) throws -> [CASignalEnrichment] {
    guard !states.isEmpty, (1...2_000).contains(limit) else {
      throw WorkspaceStoreError.invalidArgument("caSignal.states")
    }
    let orderedStates = states.sorted { $0.rawValue < $1.rawValue }
    var values = orderedStates.map { SQLiteValue.text($0.rawValue) }
    values.append(.int64(Int64(limit)))
    let statement = try prepare(
      """
      SELECT enrichment_json FROM ca_signal_enrichments
      WHERE state IN (\(Self.placeholders(count: orderedStates.count)))
      ORDER BY updated_at DESC
      LIMIT ?
      """,
      operation: "ca_signal_states"
    )
    defer { sqlite3_finalize(statement) }
    try bind(values, to: statement, operation: "ca_signal_states")
    return try decodeCASignalEnrichments(statement, operation: "ca_signal_states")
  }
}

private extension WorkspaceStore {
  func decodeCASignalEnrichments(
    _ statement: OpaquePointer,
    operation: String
  ) throws -> [CASignalEnrichment] {
    var enrichments: [CASignalEnrichment] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        do {
          enrichments.append(
            try Self.makeJSONDecoder().decode(
              CASignalEnrichment.self,
              from: requiredData(statement, column: 0)
            )
          )
        } catch {
          throw WorkspaceStoreError.queryFailed(
            operation: "\(operation)_decode",
            reason: Self.codingFailureReason(error)
          )
        }
      case SQLITE_DONE:
        return enrichments
      default:
        throw queryError(operation)
      }
    }
  }
}

// MARK: - Trade automation

public extension WorkspaceStore {
  @discardableResult
  func saveTradeAutomationConfiguration(
    _ configuration: TradeAutomationConfiguration,
    now: Date = Date()
  ) throws -> TradeAutomationConfiguration {
    let normalized = configuration.normalized
    let data: Data
    do {
      data = try Self.makeJSONEncoder().encode(normalized)
    } catch {
      throw WorkspaceStoreError.invalidArgument("tradeAutomation.configuration")
    }
    try executePrepared(
      """
      INSERT INTO trade_automation_configuration(singleton_id, configuration_json, updated_at)
      VALUES (1, ?, ?)
      ON CONFLICT(singleton_id) DO UPDATE SET
        configuration_json = excluded.configuration_json,
        updated_at = excluded.updated_at
      """,
      values: [.blob(data), .double(now.timeIntervalSince1970)],
      operation: "trade_configuration_save"
    )
    return normalized
  }

  func tradeAutomationConfiguration() throws -> TradeAutomationConfiguration? {
    let statement = try prepare(
      "SELECT configuration_json FROM trade_automation_configuration WHERE singleton_id = 1",
      operation: "trade_configuration_read"
    )
    defer { sqlite3_finalize(statement) }
    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      do {
        return try Self.makeJSONDecoder().decode(
          TradeAutomationConfiguration.self,
          from: requiredData(statement, column: 0)
        ).normalized
      } catch {
        throw WorkspaceStoreError.queryFailed(
          operation: "trade_configuration_decode",
          reason: Self.codingFailureReason(error)
        )
      }
    case SQLITE_DONE:
      return nil
    default:
      throw queryError("trade_configuration_read")
    }
  }

  @discardableResult
  func saveTradeAutomationRule(
    _ rule: TradeAutomationRule,
    now: Date = Date()
  ) throws -> TradeAutomationRule {
    guard rule.validationIssues.isEmpty else {
      throw WorkspaceStoreError.invalidArgument(
        "tradeAutomation.rule: \(rule.validationIssues.joined(separator: ", "))"
      )
    }
    var normalized = rule.normalized
    normalized.updatedAt = now
    let data: Data
    do {
      data = try Self.makeJSONEncoder().encode(normalized)
    } catch {
      throw WorkspaceStoreError.invalidArgument("tradeAutomation.rule.json")
    }
    try executePrepared(
      """
      INSERT INTO trade_automation_rules(rule_id, rule_json, is_enabled, updated_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(rule_id) DO UPDATE SET
        rule_json = excluded.rule_json,
        is_enabled = excluded.is_enabled,
        updated_at = excluded.updated_at
      """,
      values: [
        .text(normalized.id), .blob(data), .int64(normalized.isEnabled ? 1 : 0),
        .double(now.timeIntervalSince1970),
      ],
      operation: "trade_rule_save"
    )
    return normalized
  }

  func tradeAutomationRules(enabledOnly: Bool = false) throws -> [TradeAutomationRule] {
    let statement = try prepare(
      """
      SELECT rule_json FROM trade_automation_rules
      \(enabledOnly ? "WHERE is_enabled = 1" : "")
      ORDER BY is_enabled DESC, updated_at DESC, rule_id ASC
      """,
      operation: "trade_rule_list"
    )
    defer { sqlite3_finalize(statement) }
    var rules: [TradeAutomationRule] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        do {
          rules.append(
            try Self.makeJSONDecoder().decode(
              TradeAutomationRule.self,
              from: requiredData(statement, column: 0)
            ).normalized
          )
        } catch {
          throw WorkspaceStoreError.queryFailed(
            operation: "trade_rule_decode",
            reason: Self.codingFailureReason(error)
          )
        }
      case SQLITE_DONE:
        return rules
      default:
        throw queryError("trade_rule_list")
      }
    }
  }

  func deleteTradeAutomationRule(id: String) throws {
    let identifier = try normalizedRequired(id, field: "tradeAutomation.ruleID")
    try executePrepared(
      "DELETE FROM trade_automation_rules WHERE rule_id = ?",
      values: [.text(identifier)],
      operation: "trade_rule_delete"
    )
  }

  @discardableResult
  func insertTradeIntent(_ intent: TradeIntent) throws -> TradeIntent {
    try validateTradeIntent(intent)
    let data = try encodeTradeIntent(intent)
    return try withTransaction {
      try executePrepared(
        """
        INSERT OR IGNORE INTO trade_intents(
          intent_id, idempotency_key, rule_id, state, chain, family, token_address,
          estimated_spend_usd, order_id, intent_json, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        values: tradeIntentValues(intent, data: data),
        operation: "trade_intent_insert"
      )
      if sqlite3_changes(database) > 0 { return intent }
      guard let existing = try tradeIntent(idempotencyKey: intent.idempotencyKey) else {
        throw WorkspaceStoreError.queryFailed(
          operation: "trade_intent_idempotency",
          reason: "conflict_without_existing_row"
        )
      }
      return existing
    }
  }

  @discardableResult
  func updateTradeIntent(_ intent: TradeIntent) throws -> TradeIntent {
    try validateTradeIntent(intent)
    let data = try encodeTradeIntent(intent)
    try executePrepared(
      """
      UPDATE trade_intents SET
        state = ?, chain = ?, estimated_spend_usd = ?, order_id = ?, intent_json = ?, updated_at = ?
      WHERE intent_id = ? AND idempotency_key = ?
      """,
      values: [
        .text(intent.state.rawValue), intent.chain.map { .text($0.rawValue) } ?? .null,
        intent.estimatedSpendUSD.map(SQLiteValue.double) ?? .null,
        intent.orderID.map(SQLiteValue.text) ?? .null, .blob(data),
        .double(intent.updatedAt.timeIntervalSince1970), .text(intent.id),
        .text(intent.idempotencyKey),
      ],
      operation: "trade_intent_update"
    )
    guard sqlite3_changes(database) > 0 else {
      throw WorkspaceStoreError.invalidArgument("tradeAutomation.intent.notFound")
    }
    return intent
  }

  func tradeIntent(id: String) throws -> TradeIntent? {
    let identifier = try normalizedRequired(id, field: "tradeAutomation.intentID")
    return try readTradeIntent(
      sql: "SELECT intent_json FROM trade_intents WHERE intent_id = ?",
      values: [.text(identifier)],
      operation: "trade_intent_read"
    )
  }

  func tradeIntent(idempotencyKey: String) throws -> TradeIntent? {
    let key = try normalizedRequired(
      idempotencyKey,
      field: "tradeAutomation.idempotencyKey"
    )
    return try readTradeIntent(
      sql: "SELECT intent_json FROM trade_intents WHERE idempotency_key = ?",
      values: [.text(key)],
      operation: "trade_intent_idempotency_read"
    )
  }

  func tradeIntents(
    states: Set<TradeIntentState> = [],
    limit: Int = 200
  ) throws -> [TradeIntent] {
    guard (1...2_000).contains(limit) else {
      throw WorkspaceStoreError.invalidArgument("tradeAutomation.intent.limit")
    }
    let orderedStates = states.sorted { $0.rawValue < $1.rawValue }
    let clause = orderedStates.isEmpty
      ? ""
      : "WHERE state IN (\(Self.placeholders(count: orderedStates.count)))"
    var values = orderedStates.map { SQLiteValue.text($0.rawValue) }
    values.append(.int64(Int64(limit)))
    let statement = try prepare(
      """
      SELECT intent_json FROM trade_intents
      \(clause)
      ORDER BY created_at DESC, intent_id DESC
      LIMIT ?
      """,
      operation: "trade_intent_list"
    )
    defer { sqlite3_finalize(statement) }
    try bind(values, to: statement, operation: "trade_intent_list")
    var intents: [TradeIntent] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        intents.append(try decodeTradeIntent(requiredData(statement, column: 0)))
      case SQLITE_DONE:
        return intents
      default:
        throw queryError("trade_intent_list")
      }
    }
  }

  func tradeIntentCount(ruleID: String, since: Date) throws -> Int {
    let identifier = try normalizedRequired(ruleID, field: "tradeAutomation.ruleID")
    return try countTradeIntents(
      where: "rule_id = ? AND created_at >= ? AND \(Self.countedTradeStateClause)",
      values: [.text(identifier), .double(since.timeIntervalSince1970)],
      operation: "trade_intent_rule_count"
    )
  }

  func latestTradeIntentDate(
    family: CryptoAddressFamily,
    chain: GMGNChain? = nil,
    tokenAddress: String
  ) throws -> Date? {
    let address = try normalizedRequired(tokenAddress, field: "tradeAutomation.tokenAddress")
    let statement = try prepare(
      """
      SELECT created_at FROM trade_intents
      WHERE family = ? AND token_address = ?
        AND (? IS NULL OR chain = ?)
        AND \(Self.countedTradeStateClause)
      ORDER BY created_at DESC LIMIT 1
      """,
      operation: "trade_intent_token_latest"
    )
    defer { sqlite3_finalize(statement) }
    try bind(
      [
        .text(family.rawValue), .text(address),
        chain.map { .text($0.rawValue) } ?? .null,
        chain.map { .text($0.rawValue) } ?? .null,
      ],
      to: statement,
      operation: "trade_intent_token_latest"
    )
    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    case SQLITE_DONE:
      return nil
    default:
      throw queryError("trade_intent_token_latest")
    }
  }

  func tradeAutomationMetrics(now: Date = Date()) throws -> TradeAutomationMetrics {
    let dayStart = Calendar.current.startOfDay(for: now)
    let dailyCount = try countTradeIntents(
      where: "created_at >= ? AND \(Self.countedTradeStateClause)",
      values: [.double(dayStart.timeIntervalSince1970)],
      operation: "trade_metrics_daily_count"
    )

    let spendStatement = try prepare(
      """
      SELECT COALESCE(SUM(estimated_spend_usd), 0) FROM trade_intents
      WHERE created_at >= ? AND \(Self.countedTradeStateClause)
      """,
      operation: "trade_metrics_daily_spend"
    )
    defer { sqlite3_finalize(spendStatement) }
    try bind(
      [.double(dayStart.timeIntervalSince1970)],
      to: spendStatement,
      operation: "trade_metrics_daily_spend"
    )
    guard sqlite3_step(spendStatement) == SQLITE_ROW else {
      throw queryError("trade_metrics_daily_spend")
    }
    let spend = sqlite3_column_double(spendStatement, 0)

    let allRecent = try tradeIntents(limit: 2_000)
    var openPositionKeys = Set<String>()
    for intent in allRecent.reversed()
      where intent.state == .confirmed || intent.state == .unprotectedPosition
    {
      let address = intent.chain == .sol
        ? intent.tokenAddress : intent.tokenAddress.lowercased()
      let key = "\(intent.chain?.rawValue ?? "unknown")|\(address)"
      if intent.resolvedSide == .sell, intent.sellPercent == 100 {
        openPositionKeys.remove(key)
      } else if intent.resolvedSide == .buy {
        openPositionKeys.insert(key)
      }
    }

    let recent = Array(allRecent.prefix(100))
    var consecutiveFailures = 0
    for intent in recent {
      if intent.state == .failed {
        consecutiveFailures += 1
      } else if intent.state != .rejected && intent.state != .detected {
        break
      }
    }
    return TradeAutomationMetrics(
      dailyIntentCount: dailyCount,
      dailyEstimatedSpendUSD: spend,
      openPositionCount: openPositionKeys.count,
      consecutiveFailureCount: consecutiveFailures
    )
  }
}

private extension WorkspaceStore {
  static let countedTradeStateClause = """
    state IN (
      'eligible', 'simulated', 'awaiting_confirmation', 'quoted',
      'submitting', 'pending', 'confirmed', 'failed', 'unprotected_position'
    )
    """

  func validateTradeIntent(_ intent: TradeIntent) throws {
    guard !intent.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !intent.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !intent.ruleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !intent.tokenAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      intent.mentionCount >= 1,
      intent.distinctGroupCount >= 1,
      intent.inputAmountNative.isFinite,
      intent.inputAmountNative > 0,
      intent.createdAt.timeIntervalSince1970.isFinite,
      intent.updatedAt.timeIntervalSince1970.isFinite
    else {
      throw WorkspaceStoreError.invalidArgument("tradeAutomation.intent")
    }
  }

  func encodeTradeIntent(_ intent: TradeIntent) throws -> Data {
    do {
      return try Self.makeJSONEncoder().encode(intent)
    } catch {
      throw WorkspaceStoreError.invalidArgument("tradeAutomation.intent.json")
    }
  }

  func decodeTradeIntent(_ data: Data) throws -> TradeIntent {
    do {
      return try Self.makeJSONDecoder().decode(TradeIntent.self, from: data)
    } catch {
      throw WorkspaceStoreError.queryFailed(
        operation: "trade_intent_decode",
        reason: Self.codingFailureReason(error)
      )
    }
  }

  func tradeIntentValues(_ intent: TradeIntent, data: Data) -> [SQLiteValue] {
    [
      .text(intent.id), .text(intent.idempotencyKey), .text(intent.ruleID),
      .text(intent.state.rawValue), intent.chain.map { .text($0.rawValue) } ?? .null,
      .text(intent.family.rawValue), .text(intent.tokenAddress),
      intent.estimatedSpendUSD.map(SQLiteValue.double) ?? .null,
      intent.orderID.map(SQLiteValue.text) ?? .null, .blob(data),
      .double(intent.createdAt.timeIntervalSince1970),
      .double(intent.updatedAt.timeIntervalSince1970),
    ]
  }

  func readTradeIntent(
    sql: String,
    values: [SQLiteValue],
    operation: String
  ) throws -> TradeIntent? {
    let statement = try prepare(sql, operation: operation)
    defer { sqlite3_finalize(statement) }
    try bind(values, to: statement, operation: operation)
    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      return try decodeTradeIntent(requiredData(statement, column: 0))
    case SQLITE_DONE:
      return nil
    default:
      throw queryError(operation)
    }
  }

  func countTradeIntents(
    where clause: String,
    values: [SQLiteValue],
    operation: String
  ) throws -> Int {
    let statement = try prepare(
      "SELECT COUNT(*) FROM trade_intents WHERE \(clause)",
      operation: operation
    )
    defer { sqlite3_finalize(statement) }
    try bind(values, to: statement, operation: operation)
    guard sqlite3_step(statement) == SQLITE_ROW else { throw queryError(operation) }
    return Int(sqlite3_column_int64(statement, 0))
  }
}

// MARK: - SQLite implementation

private extension WorkspaceStore {
  enum SQLiteValue {
    case null
    case int64(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
  }

  static let migration1SQL = """
    CREATE TABLE workspace_schema_migrations(
      version INTEGER PRIMARY KEY,
      applied_at REAL NOT NULL
    );

    CREATE TABLE ai_provider_configurations(
      configuration_id TEXT PRIMARY KEY,
      configuration_json BLOB NOT NULL,
      is_default INTEGER NOT NULL DEFAULT 0 CHECK(is_default IN (0, 1)),
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL
    );
    CREATE UNIQUE INDEX ai_provider_single_default_idx
      ON ai_provider_configurations(is_default)
      WHERE is_default = 1;

    CREATE TABLE analysis_jobs(
      job_id TEXT PRIMARY KEY,
      frozen_range_id TEXT NOT NULL,
      provider_id TEXT NOT NULL,
      mode TEXT NOT NULL CHECK(mode IN (
        'digest', 'important_information', 'action_items', 'risks_and_opportunities', 'custom'
      )),
      custom_instructions TEXT,
      state TEXT NOT NULL CHECK(state IN (
        'pending', 'running', 'retry_wait', 'succeeded', 'failed', 'cancelled'
      )),
      attempt INTEGER NOT NULL DEFAULT 0 CHECK(attempt >= 0),
      maximum_attempts INTEGER NOT NULL CHECK(maximum_attempts >= 1),
      next_attempt_at REAL,
      idempotency_key TEXT NOT NULL UNIQUE,
      prompt_version INTEGER NOT NULL CHECK(prompt_version >= 1),
      last_error TEXT,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL,
      CHECK(attempt <= maximum_attempts)
    );
    CREATE INDEX analysis_jobs_runnable_idx
      ON analysis_jobs(state, next_attempt_at, created_at);
    CREATE INDEX analysis_jobs_range_idx
      ON analysis_jobs(frozen_range_id, created_at DESC);
    CREATE INDEX analysis_jobs_provider_idx
      ON analysis_jobs(provider_id, created_at DESC);

    CREATE TABLE analysis_results(
      analysis_id TEXT PRIMARY KEY,
      job_id TEXT NOT NULL UNIQUE REFERENCES analysis_jobs(job_id) ON DELETE CASCADE,
      frozen_range_id TEXT NOT NULL,
      result_json BLOB NOT NULL,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL
    );
    CREATE INDEX analysis_results_range_idx
      ON analysis_results(frozen_range_id, created_at DESC);

    CREATE TABLE message_rules(
      rule_id TEXT PRIMARY KEY,
      rule_json BLOB NOT NULL,
      priority INTEGER NOT NULL,
      is_enabled INTEGER NOT NULL CHECK(is_enabled IN (0, 1)),
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL
    );
    CREATE INDEX message_rules_order_idx
      ON message_rules(priority DESC, rule_id ASC);

    CREATE TABLE workspace_alerts(
      alert_id TEXT PRIMARY KEY,
      severity TEXT NOT NULL CHECK(severity IN ('information', 'warning', 'critical')),
      title TEXT NOT NULL,
      body TEXT,
      source_event_ids_json BLOB NOT NULL,
      deduplication_key TEXT NOT NULL,
      cooldown_until REAL,
      occurrence_count INTEGER NOT NULL DEFAULT 1 CHECK(occurrence_count >= 1),
      rule_id TEXT,
      acknowledged_at REAL,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL
    );
    CREATE INDEX workspace_alerts_dedupe_idx
      ON workspace_alerts(deduplication_key, cooldown_until DESC, updated_at DESC);
    CREATE INDEX workspace_alerts_unacknowledged_idx
      ON workspace_alerts(acknowledged_at, severity, created_at DESC);
    """

  static let migration2SQL = """
    CREATE TABLE crypto_address_mentions(
      event_id TEXT NOT NULL,
      family TEXT NOT NULL CHECK(family IN ('evm', 'solana')),
      normalized_address TEXT NOT NULL,
      original_address TEXT NOT NULL,
      group_name TEXT NOT NULL,
      sender_key TEXT,
      observed_at REAL NOT NULL,
      detector_version INTEGER NOT NULL CHECK(detector_version >= 1),
      created_at REAL NOT NULL,
      PRIMARY KEY(event_id, family, normalized_address)
    );
    CREATE INDEX crypto_address_mentions_lookup_idx
      ON crypto_address_mentions(family, normalized_address, observed_at);

    CREATE TABLE crypto_address_incidents(
      incident_id TEXT PRIMARY KEY,
      family TEXT NOT NULL CHECK(family IN ('evm', 'solana')),
      normalized_address TEXT NOT NULL,
      original_address TEXT NOT NULL,
      first_seen_at REAL NOT NULL,
      latest_seen_at REAL NOT NULL,
      mention_count INTEGER NOT NULL CHECK(mention_count >= 2),
      group_names_json BLOB NOT NULL,
      source_event_ids_json BLOB NOT NULL,
      alert_id TEXT NOT NULL UNIQUE REFERENCES workspace_alerts(alert_id) ON DELETE CASCADE,
      status TEXT NOT NULL CHECK(status IN ('active', 'closed')),
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL
    );
    CREATE INDEX crypto_address_incidents_lookup_idx
      ON crypto_address_incidents(family, normalized_address, status, latest_seen_at DESC);
    """

  static let migration3SQL = """
    CREATE TABLE ca_signal_enrichments(
      event_id TEXT NOT NULL,
      family TEXT NOT NULL CHECK(family IN ('evm', 'solana')),
      normalized_address TEXT NOT NULL,
      enrichment_json BLOB NOT NULL,
      state TEXT NOT NULL CHECK(state IN ('pending', 'resolved', 'failed')),
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL,
      PRIMARY KEY(event_id, family, normalized_address)
    );
    CREATE INDEX ca_signal_enrichments_event_idx
      ON ca_signal_enrichments(event_id, updated_at DESC);
    CREATE INDEX ca_signal_enrichments_address_idx
      ON ca_signal_enrichments(family, normalized_address, state, updated_at DESC);

    CREATE TABLE ca_watch_pool_items(
      family TEXT NOT NULL CHECK(family IN ('evm', 'solana')),
      normalized_address TEXT NOT NULL,
      item_json BLOB NOT NULL,
      state TEXT NOT NULL CHECK(state IN ('pending', 'watching', 'removed')),
      is_pinned INTEGER NOT NULL CHECK(is_pinned IN (0, 1)),
      latest_seen_at REAL NOT NULL,
      updated_at REAL NOT NULL,
      PRIMARY KEY(family, normalized_address)
    );
    CREATE INDEX ca_watch_pool_items_state_idx
      ON ca_watch_pool_items(state, is_pinned DESC, latest_seen_at DESC);

    CREATE TABLE ca_watch_pool_configuration(
      singleton_id INTEGER PRIMARY KEY CHECK(singleton_id = 1),
      configuration_json BLOB NOT NULL,
      updated_at REAL NOT NULL
    );
    """

  static let migration4SQL = """
    CREATE TABLE trade_automation_configuration(
      singleton_id INTEGER PRIMARY KEY CHECK(singleton_id = 1),
      configuration_json BLOB NOT NULL,
      updated_at REAL NOT NULL
    );

    CREATE TABLE trade_automation_rules(
      rule_id TEXT PRIMARY KEY,
      rule_json BLOB NOT NULL,
      is_enabled INTEGER NOT NULL CHECK(is_enabled IN (0, 1)),
      updated_at REAL NOT NULL
    );
    CREATE INDEX trade_automation_rules_enabled_idx
      ON trade_automation_rules(is_enabled, updated_at DESC);

    CREATE TABLE trade_intents(
      intent_id TEXT PRIMARY KEY,
      idempotency_key TEXT NOT NULL UNIQUE,
      rule_id TEXT NOT NULL,
      state TEXT NOT NULL CHECK(state IN (
        'detected', 'rejected', 'eligible', 'simulated', 'awaiting_confirmation',
        'quoted', 'submitting', 'pending', 'confirmed', 'failed', 'unprotected_position'
      )),
      chain TEXT,
      family TEXT NOT NULL CHECK(family IN ('evm', 'solana')),
      token_address TEXT NOT NULL,
      estimated_spend_usd REAL,
      order_id TEXT,
      intent_json BLOB NOT NULL,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL
    );
    CREATE INDEX trade_intents_state_created_idx
      ON trade_intents(state, created_at DESC);
    CREATE INDEX trade_intents_token_created_idx
      ON trade_intents(family, token_address, created_at DESC);
    CREATE INDEX trade_intents_rule_created_idx
      ON trade_intents(rule_id, created_at DESC);
    CREATE UNIQUE INDEX trade_intents_order_id_idx
      ON trade_intents(order_id)
      WHERE order_id IS NOT NULL;
    """

  /// Adds a concrete network dimension to address-derived tables. Existing rows are
  /// intentionally copied as unknown EVM/Solana rather than guessed from historical text.
  static let migration5SQL = """
    ALTER TABLE crypto_address_mentions RENAME TO crypto_address_mentions_legacy;
    DROP INDEX IF EXISTS crypto_address_mentions_lookup_idx;
    CREATE TABLE crypto_address_mentions(
      event_id TEXT NOT NULL,
      family TEXT NOT NULL CHECK(family IN ('evm', 'solana')),
      network TEXT NOT NULL,
      normalized_address TEXT NOT NULL,
      original_address TEXT NOT NULL,
      group_name TEXT NOT NULL,
      sender_key TEXT,
      observed_at REAL NOT NULL,
      detector_version INTEGER NOT NULL CHECK(detector_version >= 1),
      created_at REAL NOT NULL,
      PRIMARY KEY(event_id, family, network, normalized_address)
    );
    INSERT INTO crypto_address_mentions(
      event_id, family, network, normalized_address, original_address, group_name,
      sender_key, observed_at, detector_version, created_at
    ) SELECT event_id, family,
      CASE WHEN family = 'solana' THEN 'solana' ELSE 'evm' END,
      normalized_address, original_address, group_name, sender_key, observed_at,
      detector_version, created_at
    FROM crypto_address_mentions_legacy;
    DROP TABLE crypto_address_mentions_legacy;
    CREATE INDEX crypto_address_mentions_lookup_idx
      ON crypto_address_mentions(family, network, normalized_address, observed_at);

    ALTER TABLE crypto_address_incidents RENAME TO crypto_address_incidents_legacy;
    DROP INDEX IF EXISTS crypto_address_incidents_lookup_idx;
    CREATE TABLE crypto_address_incidents(
      incident_id TEXT PRIMARY KEY,
      family TEXT NOT NULL CHECK(family IN ('evm', 'solana')),
      network TEXT NOT NULL,
      normalized_address TEXT NOT NULL,
      original_address TEXT NOT NULL,
      first_seen_at REAL NOT NULL,
      latest_seen_at REAL NOT NULL,
      mention_count INTEGER NOT NULL CHECK(mention_count >= 2),
      group_names_json BLOB NOT NULL,
      source_event_ids_json BLOB NOT NULL,
      alert_id TEXT NOT NULL UNIQUE REFERENCES workspace_alerts(alert_id) ON DELETE CASCADE,
      status TEXT NOT NULL CHECK(status IN ('active', 'closed')),
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL
    );
    INSERT INTO crypto_address_incidents(
      incident_id, family, network, normalized_address, original_address, first_seen_at,
      latest_seen_at, mention_count, group_names_json, source_event_ids_json, alert_id,
      status, created_at, updated_at
    ) SELECT incident_id, family,
      CASE WHEN family = 'solana' THEN 'solana' ELSE 'evm' END,
      normalized_address, original_address, first_seen_at, latest_seen_at, mention_count,
      group_names_json, source_event_ids_json, alert_id, status, created_at, updated_at
    FROM crypto_address_incidents_legacy;
    DROP TABLE crypto_address_incidents_legacy;
    CREATE INDEX crypto_address_incidents_lookup_idx
      ON crypto_address_incidents(family, network, normalized_address, status, latest_seen_at DESC);

    ALTER TABLE ca_signal_enrichments RENAME TO ca_signal_enrichments_legacy;
    DROP INDEX IF EXISTS ca_signal_enrichments_event_idx;
    DROP INDEX IF EXISTS ca_signal_enrichments_address_idx;
    CREATE TABLE ca_signal_enrichments(
      event_id TEXT NOT NULL,
      family TEXT NOT NULL CHECK(family IN ('evm', 'solana')),
      network TEXT NOT NULL,
      normalized_address TEXT NOT NULL,
      enrichment_json BLOB NOT NULL,
      state TEXT NOT NULL CHECK(state IN ('pending', 'resolved', 'failed')),
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL,
      PRIMARY KEY(event_id, family, network, normalized_address)
    );
    INSERT INTO ca_signal_enrichments(
      event_id, family, network, normalized_address, enrichment_json, state, created_at, updated_at
    ) SELECT event_id, family,
      CASE WHEN family = 'solana' THEN 'solana' ELSE 'evm' END,
      normalized_address, enrichment_json, state, created_at, updated_at
    FROM ca_signal_enrichments_legacy;
    DROP TABLE ca_signal_enrichments_legacy;
    CREATE INDEX ca_signal_enrichments_event_idx
      ON ca_signal_enrichments(event_id, updated_at DESC);
    CREATE INDEX ca_signal_enrichments_address_idx
      ON ca_signal_enrichments(family, network, normalized_address, state, updated_at DESC);

    ALTER TABLE ca_watch_pool_items RENAME TO ca_watch_pool_items_legacy;
    DROP INDEX IF EXISTS ca_watch_pool_items_state_idx;
    CREATE TABLE ca_watch_pool_items(
      family TEXT NOT NULL CHECK(family IN ('evm', 'solana')),
      network TEXT NOT NULL,
      normalized_address TEXT NOT NULL,
      item_json BLOB NOT NULL,
      state TEXT NOT NULL CHECK(state IN ('pending', 'watching', 'removed')),
      is_pinned INTEGER NOT NULL CHECK(is_pinned IN (0, 1)),
      latest_seen_at REAL NOT NULL,
      updated_at REAL NOT NULL,
      PRIMARY KEY(family, network, normalized_address)
    );
    INSERT INTO ca_watch_pool_items(
      family, network, normalized_address, item_json, state, is_pinned, latest_seen_at, updated_at
    ) SELECT family,
      CASE WHEN family = 'solana' THEN 'solana' ELSE 'evm' END,
      normalized_address, item_json, state, is_pinned, latest_seen_at, updated_at
    FROM ca_watch_pool_items_legacy;
    DROP TABLE ca_watch_pool_items_legacy;
    CREATE INDEX ca_watch_pool_items_state_idx
      ON ca_watch_pool_items(state, is_pinned DESC, latest_seen_at DESC);
    """

  static let migration6SQL = """
    CREATE TABLE dex_chain_resolution_cache(
      normalized_address TEXT PRIMARY KEY,
      chain TEXT NOT NULL CHECK(chain IN ('eth', 'base', 'bsc', 'robinhood')),
      resolution_json BLOB NOT NULL,
      resolved_at REAL NOT NULL,
      last_accessed_at REAL NOT NULL
    );
    CREATE INDEX dex_chain_resolution_cache_access_idx
      ON dex_chain_resolution_cache(last_accessed_at DESC);
    """

  static func prepareParentDirectory(for databaseURL: URL) throws {
    let directory = databaseURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      throw WorkspaceStoreError.cannotOpenDatabase(databaseURL.path)
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
      throw WorkspaceStoreError.configurationFailed("journal_mode=\(mode)")
    }
    return mode
  }

  static func integerPragma(_ database: OpaquePointer, name: String) throws -> Int {
    let allowedNames = ["foreign_keys", "user_version"]
    guard allowedNames.contains(name) else {
      throw WorkspaceStoreError.configurationFailed("unsupported_pragma")
    }
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
    var currentVersion = try integerPragma(database, name: "user_version")
    guard currentVersion <= currentSchemaVersion else {
      throw WorkspaceStoreError.schemaTooNew(currentVersion)
    }
    if currentVersion < 1 {
      try applyMigration(database, version: 1, sql: migration1SQL)
      currentVersion = 1
    }
    if currentVersion < 2 {
      try applyMigration(database, version: 2, sql: migration2SQL)
      currentVersion = 2
    }
    if currentVersion < 3 {
      try applyMigration(database, version: 3, sql: migration3SQL)
      currentVersion = 3
    }
    if currentVersion < 4 {
      try applyMigration(database, version: 4, sql: migration4SQL)
      currentVersion = 4
    }
    if currentVersion < 5 {
      try applyMigration(database, version: 5, sql: migration5SQL)
      currentVersion = 5
    }
    if currentVersion < 6 {
      try applyMigration(database, version: 6, sql: migration6SQL)
      currentVersion = 6
    }
    return currentSchemaVersion
  }

  static func applyMigration(_ database: OpaquePointer, version: Int, sql: String) throws {
    do {
      try execute(database, sql: "BEGIN IMMEDIATE", operation: "migration_begin")
      try execute(database, sql: sql, operation: "migration_ddl")
      try executePrepared(
        database,
        sql: "INSERT INTO workspace_schema_migrations(version, applied_at) VALUES (?, ?)",
        values: [.int64(Int64(version)), .double(Date().timeIntervalSince1970)],
        operation: "migration_record"
      )
      try execute(
        database,
        sql: "PRAGMA user_version = \(version)",
        operation: "migration_version"
      )
      try execute(database, sql: "COMMIT", operation: "migration_commit")
    } catch {
      try? execute(database, sql: "ROLLBACK", operation: "migration_rollback")
      throw WorkspaceStoreError.migrationFailed(
        version: version,
        reason: sqliteMessage(database)
      )
    }
  }

  static func recoverRunningJobs(_ database: OpaquePointer, now: Date) throws -> Int {
    try execute(database, sql: "BEGIN IMMEDIATE", operation: "job_recovery_begin")
    do {
      // An interrupted claim is retried without consuming the retry budget.
      try executePrepared(
        database,
        sql: """
          UPDATE analysis_jobs
          SET state = ?,
              attempt = CASE WHEN attempt > 0 THEN attempt - 1 ELSE 0 END,
              next_attempt_at = ?,
              last_error = ?,
              updated_at = ?
          WHERE state = ?
          """,
        values: [
          .text(AIAnalysisJobState.pending.rawValue),
          .double(now.timeIntervalSince1970),
          .text("interrupted_execution_recovered"),
          .double(now.timeIntervalSince1970),
          .text(AIAnalysisJobState.running.rawValue),
        ],
        operation: "job_recovery_update"
      )
      let recovered = Int(sqlite3_changes(database))
      try execute(database, sql: "COMMIT", operation: "job_recovery_commit")
      return recovered
    } catch {
      try? execute(database, sql: "ROLLBACK", operation: "job_recovery_rollback")
      throw error
    }
  }

  static func execute(_ database: OpaquePointer, sql: String, operation: String) throws {
    var errorPointer: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &errorPointer)
    if let errorPointer { sqlite3_free(errorPointer) }
    guard result == SQLITE_OK else {
      throw WorkspaceStoreError.queryFailed(
        operation: operation,
        reason: sqliteMessage(database)
      )
    }
  }

  static func executePrepared(
    _ database: OpaquePointer,
    sql: String,
    values: [SQLiteValue],
    operation: String
  ) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw WorkspaceStoreError.queryFailed(
        operation: operation,
        reason: sqliteMessage(database)
      )
    }
    defer { sqlite3_finalize(statement) }
    try bindStatic(values, to: statement, database: database, operation: operation)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw WorkspaceStoreError.queryFailed(
        operation: operation,
        reason: sqliteMessage(database)
      )
    }
  }

  static func bindStatic(
    _ values: [SQLiteValue],
    to statement: OpaquePointer,
    database: OpaquePointer,
    operation: String
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
        throw WorkspaceStoreError.queryFailed(
          operation: operation,
          reason: sqliteMessage(database)
        )
      }
    }
  }

  static var sqliteTransientDestructor: sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  }

  static func configurationError(
    _ database: OpaquePointer,
    operation: String
  ) -> WorkspaceStoreError {
    .configurationFailed("\(operation): \(sqliteMessage(database))")
  }

  static func sqliteMessage(_ database: OpaquePointer) -> String {
    sqlite3_errmsg(database).map(String.init(cString:)) ?? "unknown SQLite error"
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
    try Self.bindStatic(values, to: statement, database: database, operation: operation)
  }

  func executePrepared(
    _ sql: String,
    values: [SQLiteValue],
    operation: String
  ) throws {
    try Self.executePrepared(database, sql: sql, values: values, operation: operation)
  }

  func queryError(_ operation: String) -> WorkspaceStoreError {
    .queryFailed(operation: operation, reason: Self.sqliteMessage(database))
  }

  func withTransaction<T>(_ body: () throws -> T) throws -> T {
    try Self.execute(database, sql: "BEGIN IMMEDIATE", operation: "transaction_begin")
    do {
      let result = try body()
      try Self.execute(database, sql: "COMMIT", operation: "transaction_commit")
      return result
    } catch {
      try? Self.execute(database, sql: "ROLLBACK", operation: "transaction_rollback")
      throw error
    }
  }

  func normalizedRequired(_ value: String, field: String) throws -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.count <= 1_024 else {
      throw WorkspaceStoreError.invalidArgument(field)
    }
    return normalized
  }

  func normalizedEVMAddress(_ value: String) throws -> String {
    let address = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard address.count == 42,
      address.hasPrefix("0x"),
      address.dropFirst(2).allSatisfy(\.isHexDigit)
    else {
      throw WorkspaceStoreError.invalidArgument("dexChainCache.address")
    }
    return address
  }

  func providerExists(_ identifier: String) throws -> Bool {
    try rowExists(
      sql: "SELECT 1 FROM ai_provider_configurations WHERE configuration_id = ? LIMIT 1",
      values: [.text(identifier)],
      operation: "provider_exists"
    )
  }

  func ruleExists(_ identifier: String) throws -> Bool {
    try rowExists(
      sql: "SELECT 1 FROM message_rules WHERE rule_id = ? LIMIT 1",
      values: [.text(identifier)],
      operation: "rule_exists"
    )
  }

  func rowExists(sql: String, values: [SQLiteValue], operation: String) throws -> Bool {
    let statement = try prepare(sql, operation: operation)
    defer { sqlite3_finalize(statement) }
    try bind(values, to: statement, operation: operation)
    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      return true
    case SQLITE_DONE:
      return false
    default:
      throw queryError(operation)
    }
  }

  func encodeProviderConfiguration(_ configuration: AIProviderConfiguration) throws -> Data {
    do {
      return try Self.makeJSONEncoder().encode(configuration)
    } catch {
      throw WorkspaceStoreError.providerConfigurationEncodingFailed(
        configurationID: configuration.configurationID,
        reason: Self.codingFailureReason(error)
      )
    }
  }

  func decodeProviderConfiguration(_ data: Data, expectedID: String) throws
    -> AIProviderConfiguration
  {
    do {
      let configuration = try Self.makeJSONDecoder().decode(
        AIProviderConfiguration.self,
        from: data
      )
      guard configuration.configurationID == expectedID else {
        throw WorkspaceStoreError.providerConfigurationDecodingFailed(
          configurationID: expectedID,
          reason: "identifier_mismatch"
        )
      }
      return configuration
    } catch let error as WorkspaceStoreError {
      throw error
    } catch {
      throw WorkspaceStoreError.providerConfigurationDecodingFailed(
        configurationID: expectedID,
        reason: Self.codingFailureReason(error)
      )
    }
  }

  func encodeMessageRule(_ rule: MessageRule) throws -> Data {
    do {
      return try Self.makeJSONEncoder().encode(rule)
    } catch {
      throw WorkspaceStoreError.messageRuleEncodingFailed(
        ruleID: rule.id,
        reason: Self.codingFailureReason(error)
      )
    }
  }

  func decodeMessageRule(_ data: Data, expectedID: String) throws -> MessageRule {
    do {
      let rule = try Self.makeJSONDecoder().decode(MessageRule.self, from: data)
      guard rule.id == expectedID else {
        throw WorkspaceStoreError.messageRuleDecodingFailed(
          ruleID: expectedID,
          reason: "identifier_mismatch"
        )
      }
      return rule
    } catch let error as WorkspaceStoreError {
      throw error
    } catch {
      throw WorkspaceStoreError.messageRuleDecodingFailed(
        ruleID: expectedID,
        reason: Self.codingFailureReason(error)
      )
    }
  }

  static func makeJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  static func makeJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }

  static func codingFailureReason(_ error: Error) -> String {
    guard let error = error as? DecodingError else {
      return String(describing: type(of: error))
    }
    switch error {
    case .dataCorrupted(let context):
      return "data_corrupted:\(codingPath(context.codingPath))"
    case .keyNotFound(let key, let context):
      return "key_not_found:\(codingPath(context.codingPath + [key]))"
    case .typeMismatch(_, let context):
      return "type_mismatch:\(codingPath(context.codingPath))"
    case .valueNotFound(_, let context):
      return "value_not_found:\(codingPath(context.codingPath))"
    @unknown default:
      return "unknown_coding_error"
    }
  }

  static func codingPath(_ path: [CodingKey]) -> String {
    let joined = path.map(\.stringValue).joined(separator: ".")
    return joined.isEmpty ? "root" : joined
  }

  func requiredText(_ statement: OpaquePointer, column: Int32) -> String {
    guard let text = sqlite3_column_text(statement, column) else { return "" }
    return String(cString: text)
  }

  func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL,
      let text = sqlite3_column_text(statement, column)
    else {
      return nil
    }
    return String(cString: text)
  }

  func requiredData(_ statement: OpaquePointer, column: Int32) -> Data {
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count > 0, let bytes = sqlite3_column_blob(statement, column) else {
      return Data()
    }
    return Data(bytes: bytes, count: count)
  }

  func optionalDate(_ statement: OpaquePointer, column: Int32) -> Date? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
  }
}

// MARK: - Message rules

public extension WorkspaceStore {
  @discardableResult
  func saveMessageRule(_ rule: MessageRule, now: Date = Date()) throws -> MessageRule {
    let identifier = try normalizedRequired(rule.id, field: "rule.id")
    guard identifier == rule.id,
      rule.schemaVersion == MessageRule.currentSchemaVersion,
      rule.revision > 0
    else {
      throw WorkspaceStoreError.invalidArgument("rule.schemaOrIdentifier")
    }
    _ = try normalizedRequired(rule.name, field: "rule.name")
    let encoded = try encodeMessageRule(rule)

    try executePrepared(
      """
      INSERT INTO message_rules(
        rule_id, rule_json, priority, is_enabled, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(rule_id) DO UPDATE SET
        rule_json = excluded.rule_json,
        priority = excluded.priority,
        is_enabled = excluded.is_enabled,
        updated_at = excluded.updated_at
      """,
      values: [
        .text(identifier), .blob(encoded), .int64(Int64(rule.priority)),
        .int64(rule.isEnabled ? 1 : 0), .double(now.timeIntervalSince1970),
        .double(now.timeIntervalSince1970),
      ],
      operation: "rule_save"
    )
    return rule
  }

  func messageRule(id: String) throws -> MessageRule? {
    let identifier = try normalizedRequired(id, field: "rule.id")
    let statement = try prepare(
      "SELECT rule_json FROM message_rules WHERE rule_id = ?",
      operation: "rule_read"
    )
    defer { sqlite3_finalize(statement) }
    try bind([.text(identifier)], to: statement, operation: "rule_read")
    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      return try decodeMessageRule(requiredData(statement, column: 0), expectedID: identifier)
    case SQLITE_DONE:
      return nil
    default:
      throw queryError("rule_read")
    }
  }

  func messageRules(includeDisabled: Bool = true) throws -> [MessageRule] {
    let statement = try prepare(
      """
      SELECT rule_id, rule_json
      FROM message_rules
      WHERE (? = 1 OR is_enabled = 1)
      ORDER BY priority DESC, rule_id ASC
      """,
      operation: "rule_list"
    )
    defer { sqlite3_finalize(statement) }
    try bind([.int64(includeDisabled ? 1 : 0)], to: statement, operation: "rule_list")
    var rules: [MessageRule] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        let identifier = requiredText(statement, column: 0)
        rules.append(
          try decodeMessageRule(requiredData(statement, column: 1), expectedID: identifier)
        )
      case SQLITE_DONE:
        return rules
      default:
        throw queryError("rule_list")
      }
    }
  }

  func deleteMessageRule(id: String) throws {
    let identifier = try normalizedRequired(id, field: "rule.id")
    try withTransaction {
      guard try ruleExists(identifier) else {
        throw WorkspaceStoreError.messageRuleNotFound(identifier)
      }
      try executePrepared(
        "DELETE FROM message_rules WHERE rule_id = ?",
        values: [.text(identifier)],
        operation: "rule_delete"
      )
    }
  }
}

// MARK: - Durable analysis queue

public extension WorkspaceStore {
  @discardableResult
  func enqueueAnalysisJob(
    frozenRangeID: String,
    providerID: String,
    mode: AIAnalysisMode,
    customInstructions: String? = nil,
    maximumAttempts: Int = 3,
    nextAttemptAt: Date? = nil,
    idempotencyKey: String,
    promptVersion: Int = 1,
    now: Date = Date()
  ) throws -> AIAnalysisJob {
    let rangeID = try normalizedRequired(frozenRangeID, field: "job.frozenRangeID")
    let providerID = try normalizedRequired(providerID, field: "job.providerID")
    let idempotencyKey = try normalizedRequired(idempotencyKey, field: "job.idempotencyKey")
    guard idempotencyKey.count <= 512 else {
      throw WorkspaceStoreError.invalidArgument("job.idempotencyKey")
    }
    guard (1...100).contains(maximumAttempts) else {
      throw WorkspaceStoreError.invalidArgument("job.maximumAttempts")
    }
    guard promptVersion > 0 else {
      throw WorkspaceStoreError.invalidArgument("job.promptVersion")
    }
    let instructions = try normalizedInstructions(customInstructions, mode: mode)

    return try withTransaction {
      if let existing = try loadJob(idempotencyKey: idempotencyKey) {
        guard existing.frozenRangeID == rangeID,
          existing.providerID == providerID,
          existing.mode == mode,
          existing.customInstructions == instructions,
          existing.maximumAttempts == maximumAttempts,
          existing.promptVersion == promptVersion
        else {
          throw WorkspaceStoreError.idempotencyConflict(idempotencyKey)
        }
        return existing
      }
      guard try providerExists(providerID) else {
        throw WorkspaceStoreError.providerConfigurationNotFound(providerID)
      }

      let jobID = UUID().uuidString.lowercased()
      try executePrepared(
        """
        INSERT INTO analysis_jobs(
          job_id, frozen_range_id, provider_id, mode, custom_instructions, state,
          attempt, maximum_attempts, next_attempt_at, idempotency_key,
          prompt_version, last_error, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        values: [
          .text(jobID), .text(rangeID), .text(providerID), .text(mode.rawValue),
          instructions.map(SQLiteValue.text) ?? .null,
          .text(AIAnalysisJobState.pending.rawValue), .int64(0),
          .int64(Int64(maximumAttempts)),
          nextAttemptAt.map { .double($0.timeIntervalSince1970) } ?? .null,
          .text(idempotencyKey), .int64(Int64(promptVersion)), .null,
          .double(now.timeIntervalSince1970), .double(now.timeIntervalSince1970),
        ],
        operation: "job_enqueue"
      )
      return try requiredJob(id: jobID)
    }
  }

  func analysisJob(id: String) throws -> AIAnalysisJob? {
    let identifier = try normalizedRequired(id, field: "job.id")
    return try loadJob(id: identifier)
  }

  func analysisJobs(
    states: Set<AIAnalysisJobState> = [],
    frozenRangeID: String? = nil,
    providerID: String? = nil,
    limit: Int = 100
  ) throws -> [AIAnalysisJob] {
    guard (1...500).contains(limit) else {
      throw WorkspaceStoreError.invalidArgument("job.limit")
    }
    let rangeID = try frozenRangeID.map {
      try normalizedRequired($0, field: "job.frozenRangeID")
    }
    let providerID = try providerID.map {
      try normalizedRequired($0, field: "job.providerID")
    }
    var clauses: [String] = []
    var values: [SQLiteValue] = []
    if !states.isEmpty {
      let ordered = states.sorted { $0.rawValue < $1.rawValue }
      clauses.append("state IN (\(Self.placeholders(count: ordered.count)))")
      values.append(contentsOf: ordered.map { .text($0.rawValue) })
    }
    if let rangeID {
      clauses.append("frozen_range_id = ?")
      values.append(.text(rangeID))
    }
    if let providerID {
      clauses.append("provider_id = ?")
      values.append(.text(providerID))
    }
    let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
    values.append(.int64(Int64(limit)))

    let statement = try prepare(
      """
      SELECT \(Self.jobSelectColumns)
      FROM analysis_jobs
      \(whereClause)
      ORDER BY created_at DESC, job_id DESC
      LIMIT ?
      """,
      operation: "job_list"
    )
    defer { sqlite3_finalize(statement) }
    try bind(values, to: statement, operation: "job_list")
    var jobs: [AIAnalysisJob] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        jobs.append(try decodeJob(statement))
      case SQLITE_DONE:
        return jobs
      default:
        throw queryError("job_list")
      }
    }
  }

  /// Returns the next due task without changing its state.
  func nextRunnableJob(now: Date = Date()) throws -> AIAnalysisJob? {
    try withTransaction {
      try nextRunnableJobUnlocked(now: now)
    }
  }

  /// Atomically selects and marks one due task running. Prefer this for workers.
  func claimNextRunnableJob(now: Date = Date()) throws -> AIAnalysisJob? {
    try withTransaction {
      guard let job = try nextRunnableJobUnlocked(now: now) else { return nil }
      return try markRunningUnlocked(job: job, now: now)
    }
  }

  @discardableResult
  func markRunning(jobID: String, now: Date = Date()) throws -> AIAnalysisJob {
    let identifier = try normalizedRequired(jobID, field: "job.id")
    return try withTransaction {
      try markRunningUnlocked(job: requiredJob(id: identifier), now: now)
    }
  }

  @discardableResult
  func reschedule(
    jobID: String,
    nextAttemptAt: Date,
    error: String,
    now: Date = Date()
  ) throws -> AIAnalysisJob {
    let identifier = try normalizedRequired(jobID, field: "job.id")
    return try withTransaction {
      let job = try requiredJob(id: identifier)
      guard job.state == .running else {
        throw WorkspaceStoreError.invalidJobTransition(
          jobID: identifier,
          from: job.state,
          to: .retryWait
        )
      }
      let sanitized = Self.sanitizedDiagnostic(error) ?? "analysis_retry_requested"
      let nextState: AIAnalysisJobState = job.attempt >= job.maximumAttempts
        ? .failed
        : .retryWait
      try executePrepared(
        """
        UPDATE analysis_jobs
        SET state = ?, next_attempt_at = ?, last_error = ?, updated_at = ?
        WHERE job_id = ? AND state = ?
        """,
        values: [
          .text(nextState.rawValue),
          nextState == .retryWait ? .double(nextAttemptAt.timeIntervalSince1970) : .null,
          .text(sanitized), .double(now.timeIntervalSince1970), .text(identifier),
          .text(AIAnalysisJobState.running.rawValue),
        ],
        operation: "job_reschedule"
      )
      guard sqlite3_changes(database) == 1 else { throw queryError("job_reschedule") }
      return try requiredJob(id: identifier)
    }
  }

  /// Releases a claimed task after local worker cancellation without consuming an attempt.
  @discardableResult
  func releaseRunningJob(
    jobID: String,
    nextAttemptAt: Date = Date(),
    error: String = "worker_cancelled",
    now: Date = Date()
  ) throws -> AIAnalysisJob {
    let identifier = try normalizedRequired(jobID, field: "job.id")
    return try withTransaction {
      let job = try requiredJob(id: identifier)
      guard job.state == .running else {
        throw WorkspaceStoreError.invalidJobTransition(
          jobID: identifier,
          from: job.state,
          to: .retryWait
        )
      }
      try executePrepared(
        """
        UPDATE analysis_jobs
        SET state = ?,
            attempt = CASE WHEN attempt > 0 THEN attempt - 1 ELSE 0 END,
            next_attempt_at = ?,
            last_error = ?,
            updated_at = ?
        WHERE job_id = ? AND state = ? AND attempt = ?
        """,
        values: [
          .text(AIAnalysisJobState.retryWait.rawValue),
          .double(nextAttemptAt.timeIntervalSince1970),
          .text(Self.sanitizedDiagnostic(error) ?? "worker_cancelled"),
          .double(now.timeIntervalSince1970), .text(identifier),
          .text(AIAnalysisJobState.running.rawValue), .int64(Int64(job.attempt)),
        ],
        operation: "job_release_running"
      )
      guard sqlite3_changes(database) == 1 else { throw queryError("job_release_running") }
      return try requiredJob(id: identifier)
    }
  }

  @discardableResult
  func fail(
    jobID: String,
    error: String,
    now: Date = Date()
  ) throws -> AIAnalysisJob {
    let identifier = try normalizedRequired(jobID, field: "job.id")
    return try withTransaction {
      let job = try requiredJob(id: identifier)
      guard job.state == .running else {
        throw WorkspaceStoreError.invalidJobTransition(
          jobID: identifier,
          from: job.state,
          to: .failed
        )
      }
      try updateJobTerminalState(
        identifier,
        expectedState: .running,
        state: .failed,
        error: Self.sanitizedDiagnostic(error) ?? "analysis_failed",
        now: now,
        operation: "job_fail"
      )
      return try requiredJob(id: identifier)
    }
  }

  @discardableResult
  func cancel(jobID: String, now: Date = Date()) throws -> AIAnalysisJob {
    let identifier = try normalizedRequired(jobID, field: "job.id")
    return try withTransaction {
      let job = try requiredJob(id: identifier)
      if job.state == .cancelled { return job }
      guard !job.state.isTerminal else {
        throw WorkspaceStoreError.invalidJobTransition(
          jobID: identifier,
          from: job.state,
          to: .cancelled
        )
      }
      try executePrepared(
        """
        UPDATE analysis_jobs
        SET state = ?, next_attempt_at = NULL, updated_at = ?
        WHERE job_id = ? AND state = ?
        """,
        values: [
          .text(AIAnalysisJobState.cancelled.rawValue),
          .double(now.timeIntervalSince1970), .text(identifier), .text(job.state.rawValue),
        ],
        operation: "job_cancel"
      )
      guard sqlite3_changes(database) == 1 else { throw queryError("job_cancel") }
      return try requiredJob(id: identifier)
    }
  }

  @discardableResult
  func complete(
    jobID: String,
    result: AIAnalysisResult,
    now: Date = Date()
  ) throws -> AIAnalysisJob {
    let identifier = try normalizedRequired(jobID, field: "job.id")
    return try withTransaction {
      let job = try requiredJob(id: identifier)
      if job.state == .succeeded,
        let existing = try loadAnalysisResult(jobID: identifier),
        try encodeAnalysisResult(existing.result) == encodeAnalysisResult(result)
      {
        return job
      }
      guard job.state == .running else {
        throw WorkspaceStoreError.invalidJobTransition(
          jobID: identifier,
          from: job.state,
          to: .succeeded
        )
      }
      try saveAnalysisResultUnlocked(result, job: job, now: now)
      try updateJobTerminalState(
        identifier,
        expectedState: .running,
        state: .succeeded,
        error: nil,
        now: now,
        operation: "job_complete"
      )
      return try requiredJob(id: identifier)
    }
  }

  nonisolated static func sanitizedDiagnostic(_ value: String?) -> String? {
    guard let value else { return nil }
    var sanitized = value.unicodeScalars.map { scalar -> String in
      CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
    }.joined()
    let patterns: [(String, String)] = [
      (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer [REDACTED]"),
      (#"(?i)\b(api[_-]?key|authorization|access[_-]?token|token)\s*[:=]\s*[^\s,;]+"#, "$1=[REDACTED]"),
      (#"(?i)([?&](?:api[_-]?key|key|token)=)[^&\s]+"#, "$1[REDACTED]"),
    ]
    for (pattern, replacement) in patterns {
      guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
      sanitized = expression.stringByReplacingMatches(
        in: sanitized,
        range: range,
        withTemplate: replacement
      )
    }
    sanitized = sanitized
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
    guard !sanitized.isEmpty else { return nil }
    return String(sanitized.prefix(2_048))
  }
}

// MARK: - Analysis results

public extension WorkspaceStore {
  @discardableResult
  func saveAnalysisResult(
    _ result: AIAnalysisResult,
    jobID: String,
    frozenRangeID: String,
    now: Date = Date()
  ) throws -> StoredAIAnalysisResult {
    let identifier = try normalizedRequired(jobID, field: "result.jobID")
    let rangeID = try normalizedRequired(frozenRangeID, field: "result.frozenRangeID")
    return try withTransaction {
      let job = try requiredJob(id: identifier)
      guard job.frozenRangeID == rangeID else {
        throw WorkspaceStoreError.analysisResultJobMismatch(analysisID: result.analysisID)
      }
      guard job.state == .succeeded else {
        throw WorkspaceStoreError.analysisResultMutationNotAllowed(
          analysisID: result.analysisID,
          jobState: job.state
        )
      }
      guard let existing = try loadAnalysisResult(jobID: identifier),
        existing.result.analysisID == result.analysisID
      else {
        throw WorkspaceStoreError.analysisResultNotFound(result.analysisID)
      }
      try saveAnalysisResultUnlocked(result, job: job, now: now)
      guard let stored = try loadAnalysisResult(id: result.analysisID) else {
        throw WorkspaceStoreError.analysisResultNotFound(result.analysisID)
      }
      return stored
    }
  }

  func analysisResult(id: String) throws -> StoredAIAnalysisResult? {
    let identifier = try normalizedRequired(id, field: "result.id")
    return try loadAnalysisResult(id: identifier)
  }

  func analysisResult(forJobID jobID: String) throws -> StoredAIAnalysisResult? {
    let identifier = try normalizedRequired(jobID, field: "result.jobID")
    return try loadAnalysisResult(jobID: identifier)
  }

  func analysisResults(frozenRangeID: String? = nil, limit: Int = 100) throws
    -> [StoredAIAnalysisResult]
  {
    guard (1...500).contains(limit) else {
      throw WorkspaceStoreError.invalidArgument("result.limit")
    }
    let rangeID = try frozenRangeID.map {
      try normalizedRequired($0, field: "result.frozenRangeID")
    }
    let statement = try prepare(
      """
      SELECT analysis_id, job_id, frozen_range_id, result_json, created_at, updated_at
      FROM analysis_results
      WHERE (? IS NULL OR frozen_range_id = ?)
      ORDER BY created_at DESC, analysis_id DESC
      LIMIT ?
      """,
      operation: "result_list"
    )
    defer { sqlite3_finalize(statement) }
    try bind(
      [
        rangeID.map(SQLiteValue.text) ?? .null,
        rangeID.map(SQLiteValue.text) ?? .null,
        .int64(Int64(limit)),
      ],
      to: statement,
      operation: "result_list"
    )
    var results: [StoredAIAnalysisResult] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        results.append(try decodeStoredAnalysisResult(statement))
      case SQLITE_DONE:
        return results
      default:
        throw queryError("result_list")
      }
    }
  }

  func deleteAnalysisResult(id: String) throws {
    let identifier = try normalizedRequired(id, field: "result.id")
    try withTransaction {
      guard let stored = try loadAnalysisResult(id: identifier) else {
        throw WorkspaceStoreError.analysisResultNotFound(identifier)
      }
      let job = try requiredJob(id: stored.jobID)
      guard job.state != .succeeded else {
        throw WorkspaceStoreError.analysisResultMutationNotAllowed(
          analysisID: identifier,
          jobState: job.state
        )
      }
      try executePrepared(
        "DELETE FROM analysis_results WHERE analysis_id = ?",
        values: [.text(identifier)],
        operation: "result_delete"
      )
    }
  }
}

private extension WorkspaceStore {
  static let jobSelectColumns = """
    job_id, frozen_range_id, provider_id, mode, custom_instructions, state,
    attempt, maximum_attempts, next_attempt_at, idempotency_key, prompt_version,
    last_error, created_at, updated_at
    """

  static func placeholders(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
  }

  func normalizedInstructions(_ value: String?, mode: AIAnalysisMode) throws -> String? {
    let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let normalized, normalized.count > AIAnalysisRequest.maximumCustomInstructionCharacters {
      throw WorkspaceStoreError.invalidArgument("job.customInstructions")
    }
    if mode == .custom, normalized?.isEmpty != false {
      throw WorkspaceStoreError.invalidArgument("job.customInstructions")
    }
    return normalized?.isEmpty == true ? nil : normalized
  }

  func loadJob(id: String) throws -> AIAnalysisJob? {
    try loadSingleJob(
      whereSQL: "job_id = ?",
      values: [.text(id)],
      operation: "job_read"
    )
  }

  func loadJob(idempotencyKey: String) throws -> AIAnalysisJob? {
    try loadSingleJob(
      whereSQL: "idempotency_key = ?",
      values: [.text(idempotencyKey)],
      operation: "job_read_idempotency"
    )
  }

  func loadSingleJob(
    whereSQL: String,
    values: [SQLiteValue],
    operation: String
  ) throws -> AIAnalysisJob? {
    let statement = try prepare(
      "SELECT \(Self.jobSelectColumns) FROM analysis_jobs WHERE \(whereSQL) LIMIT 1",
      operation: operation
    )
    defer { sqlite3_finalize(statement) }
    try bind(values, to: statement, operation: operation)
    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      return try decodeJob(statement)
    case SQLITE_DONE:
      return nil
    default:
      throw queryError(operation)
    }
  }

  func requiredJob(id: String) throws -> AIAnalysisJob {
    guard let job = try loadJob(id: id) else {
      throw WorkspaceStoreError.analysisJobNotFound(id)
    }
    return job
  }

  func decodeJob(_ statement: OpaquePointer) throws -> AIAnalysisJob {
    let identifier = requiredText(statement, column: 0)
    guard let mode = AIAnalysisMode(rawValue: requiredText(statement, column: 3)),
      let state = AIAnalysisJobState(rawValue: requiredText(statement, column: 5))
    else {
      throw WorkspaceStoreError.queryFailed(
        operation: "job_decode",
        reason: "unsupported_enum_value"
      )
    }
    return AIAnalysisJob(
      jobID: identifier,
      frozenRangeID: requiredText(statement, column: 1),
      providerID: requiredText(statement, column: 2),
      mode: mode,
      customInstructions: optionalText(statement, column: 4),
      state: state,
      attempt: Int(sqlite3_column_int64(statement, 6)),
      maximumAttempts: Int(sqlite3_column_int64(statement, 7)),
      nextAttemptAt: optionalDate(statement, column: 8),
      idempotencyKey: requiredText(statement, column: 9),
      promptVersion: Int(sqlite3_column_int64(statement, 10)),
      lastError: optionalText(statement, column: 11),
      createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12)),
      updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 13))
    )
  }

  func nextRunnableJobUnlocked(now: Date) throws -> AIAnalysisJob? {
    let statement = try prepare(
      """
      SELECT \(Self.jobSelectColumns)
      FROM analysis_jobs
      WHERE state IN (?, ?)
        AND attempt < maximum_attempts
        AND COALESCE(next_attempt_at, created_at) <= ?
      ORDER BY COALESCE(next_attempt_at, created_at) ASC, created_at ASC, job_id ASC
      LIMIT 1
      """,
      operation: "job_next_runnable"
    )
    defer { sqlite3_finalize(statement) }
    try bind(
      [
        .text(AIAnalysisJobState.pending.rawValue),
        .text(AIAnalysisJobState.retryWait.rawValue),
        .double(now.timeIntervalSince1970),
      ],
      to: statement,
      operation: "job_next_runnable"
    )
    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      return try decodeJob(statement)
    case SQLITE_DONE:
      return nil
    default:
      throw queryError("job_next_runnable")
    }
  }

  func markRunningUnlocked(job: AIAnalysisJob, now: Date) throws -> AIAnalysisJob {
    guard job.state == .pending || job.state == .retryWait,
      job.attempt < job.maximumAttempts,
      job.nextAttemptAt.map({ $0 <= now }) ?? true
    else {
      throw WorkspaceStoreError.invalidJobTransition(
        jobID: job.jobID,
        from: job.state,
        to: .running
      )
    }
    try executePrepared(
      """
      UPDATE analysis_jobs
      SET state = ?, attempt = attempt + 1, next_attempt_at = NULL, updated_at = ?
      WHERE job_id = ? AND state = ? AND attempt = ? AND attempt < maximum_attempts
      """,
      values: [
        .text(AIAnalysisJobState.running.rawValue), .double(now.timeIntervalSince1970),
        .text(job.jobID), .text(job.state.rawValue), .int64(Int64(job.attempt)),
      ],
      operation: "job_mark_running"
    )
    guard sqlite3_changes(database) == 1 else { throw queryError("job_mark_running") }
    return try requiredJob(id: job.jobID)
  }

  func updateJobTerminalState(
    _ jobID: String,
    expectedState: AIAnalysisJobState,
    state: AIAnalysisJobState,
    error: String?,
    now: Date,
    operation: String
  ) throws {
    try executePrepared(
      """
      UPDATE analysis_jobs
      SET state = ?, next_attempt_at = NULL, last_error = ?, updated_at = ?
      WHERE job_id = ? AND state = ?
      """,
      values: [
        .text(state.rawValue), error.map(SQLiteValue.text) ?? .null,
        .double(now.timeIntervalSince1970), .text(jobID), .text(expectedState.rawValue),
      ],
      operation: operation
    )
    guard sqlite3_changes(database) == 1 else { throw queryError(operation) }
  }

  func validateAnalysisResult(_ result: AIAnalysisResult, job: AIAnalysisJob) throws {
    let analysisID = try normalizedRequired(result.analysisID, field: "result.analysisID")
    let requestID = try normalizedRequired(result.requestID, field: "result.requestID")
    guard analysisID == result.analysisID, requestID == result.requestID else {
      throw WorkspaceStoreError.invalidArgument("result.identifierWhitespace")
    }
    guard result.schemaVersion == AIAnalysisResult.currentSchemaVersion,
      result.provenance.resultSchemaVersion == result.schemaVersion
    else {
      throw WorkspaceStoreError.invalidArgument("result.schemaVersion")
    }
    guard result.provenance.providerConfigurationID == job.providerID else {
      throw WorkspaceStoreError.analysisResultProviderMismatch(
        analysisID: result.analysisID
      )
    }
  }

  func encodeAnalysisResult(_ result: AIAnalysisResult) throws -> Data {
    do {
      return try Self.makeJSONEncoder().encode(result)
    } catch {
      throw WorkspaceStoreError.analysisResultEncodingFailed(
        analysisID: result.analysisID,
        reason: Self.codingFailureReason(error)
      )
    }
  }

  func decodeAnalysisResult(_ data: Data, expectedID: String) throws -> AIAnalysisResult {
    do {
      let result = try Self.makeJSONDecoder().decode(AIAnalysisResult.self, from: data)
      guard result.analysisID == expectedID,
        result.schemaVersion == AIAnalysisResult.currentSchemaVersion,
        result.provenance.resultSchemaVersion == result.schemaVersion
      else {
        throw WorkspaceStoreError.analysisResultDecodingFailed(
          analysisID: expectedID,
          reason: "identifier_or_schema_mismatch"
        )
      }
      return result
    } catch let error as WorkspaceStoreError {
      throw error
    } catch {
      throw WorkspaceStoreError.analysisResultDecodingFailed(
        analysisID: expectedID,
        reason: Self.codingFailureReason(error)
      )
    }
  }

  func saveAnalysisResultUnlocked(
    _ result: AIAnalysisResult,
    job: AIAnalysisJob,
    now: Date
  ) throws {
    try validateAnalysisResult(result, job: job)
    if let existing = try loadAnalysisResult(id: result.analysisID),
      existing.jobID != job.jobID || existing.frozenRangeID != job.frozenRangeID
    {
      throw WorkspaceStoreError.analysisResultJobMismatch(analysisID: result.analysisID)
    }
    if let existing = try loadAnalysisResult(jobID: job.jobID),
      existing.result.analysisID != result.analysisID
    {
      throw WorkspaceStoreError.analysisResultJobMismatch(analysisID: result.analysisID)
    }
    let encoded = try encodeAnalysisResult(result)
    try executePrepared(
      """
      INSERT INTO analysis_results(
        analysis_id, job_id, frozen_range_id, result_json, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(analysis_id) DO UPDATE SET
        result_json = excluded.result_json,
        updated_at = excluded.updated_at
      """,
      values: [
        .text(result.analysisID), .text(job.jobID), .text(job.frozenRangeID),
        .blob(encoded), .double(now.timeIntervalSince1970),
        .double(now.timeIntervalSince1970),
      ],
      operation: "result_save"
    )
  }

  func loadAnalysisResult(id: String) throws -> StoredAIAnalysisResult? {
    try loadSingleAnalysisResult(
      whereSQL: "analysis_id = ?",
      values: [.text(id)],
      operation: "result_read"
    )
  }

  func loadAnalysisResult(jobID: String) throws -> StoredAIAnalysisResult? {
    try loadSingleAnalysisResult(
      whereSQL: "job_id = ?",
      values: [.text(jobID)],
      operation: "result_read_job"
    )
  }

  func loadSingleAnalysisResult(
    whereSQL: String,
    values: [SQLiteValue],
    operation: String
  ) throws -> StoredAIAnalysisResult? {
    let statement = try prepare(
      """
      SELECT analysis_id, job_id, frozen_range_id, result_json, created_at, updated_at
      FROM analysis_results
      WHERE \(whereSQL)
      LIMIT 1
      """,
      operation: operation
    )
    defer { sqlite3_finalize(statement) }
    try bind(values, to: statement, operation: operation)
    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      return try decodeStoredAnalysisResult(statement)
    case SQLITE_DONE:
      return nil
    default:
      throw queryError(operation)
    }
  }

  func decodeStoredAnalysisResult(_ statement: OpaquePointer) throws
    -> StoredAIAnalysisResult
  {
    let analysisID = requiredText(statement, column: 0)
    return StoredAIAnalysisResult(
      jobID: requiredText(statement, column: 1),
      frozenRangeID: requiredText(statement, column: 2),
      result: try decodeAnalysisResult(
        requiredData(statement, column: 3),
        expectedID: analysisID
      ),
      createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
      updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
    )
  }
}

// MARK: - Alerts

public extension WorkspaceStore {
  /// Records an alert without persisting any message body unless `body` is explicitly supplied.
  @discardableResult
  func recordAlert(
    severity: MessageRuleAlertSeverity,
    title: String,
    body: String? = nil,
    sourceEventIDs: [String],
    deduplicationKey: String,
    cooldownInterval: TimeInterval = 0,
    ruleID: String? = nil,
    now: Date = Date()
  ) throws -> WorkspaceAlertRecordingResult {
    let title = try normalizedRequired(title, field: "alert.title")
    guard title.count <= 512 else {
      throw WorkspaceStoreError.invalidArgument("alert.title")
    }
    let key = try normalizedRequired(deduplicationKey, field: "alert.deduplicationKey")
    guard key.count <= 1_024 else {
      throw WorkspaceStoreError.invalidArgument("alert.deduplicationKey")
    }
    guard cooldownInterval.isFinite,
      cooldownInterval >= 0,
      cooldownInterval <= 30 * 24 * 60 * 60
    else {
      throw WorkspaceStoreError.invalidArgument("alert.cooldownInterval")
    }
    let body = body?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard body?.count ?? 0 <= 4_096 else {
      throw WorkspaceStoreError.invalidArgument("alert.body")
    }
    let bodyToStore = body?.isEmpty == true ? nil : body
    let ruleID = try ruleID.map { try normalizedRequired($0, field: "alert.ruleID") }
    let sourceIDs = try normalizedSourceEventIDs(sourceEventIDs)
    let cooldownUntil = now.addingTimeInterval(cooldownInterval)

    return try withTransaction {
      if let existing = try alertInCooldown(deduplicationKey: key, now: now) {
        var mergedIDs = existing.sourceEventIDs
        var seen = Set(mergedIDs)
        for identifier in sourceIDs where seen.insert(identifier).inserted {
          guard mergedIDs.count < 10_000 else { break }
          mergedIDs.append(identifier)
        }
        let encodedSources = try encodeAlertSources(mergedIDs, alertID: existing.alertID)
        let mergedSeverity = Self.maximumSeverity(existing.severity, severity)
        let mergedCooldown = max(existing.cooldownUntil ?? now, cooldownUntil)
        try executePrepared(
          """
          UPDATE workspace_alerts
          SET severity = ?, title = ?, body = ?, source_event_ids_json = ?,
              cooldown_until = ?, occurrence_count = occurrence_count + 1,
              rule_id = COALESCE(?, rule_id), acknowledged_at = NULL, updated_at = ?
          WHERE alert_id = ?
          """,
          values: [
            .text(mergedSeverity.rawValue), .text(title),
            (bodyToStore ?? existing.body).map(SQLiteValue.text) ?? .null,
            .blob(encodedSources), .double(mergedCooldown.timeIntervalSince1970),
            ruleID.map(SQLiteValue.text) ?? .null, .double(now.timeIntervalSince1970),
            .text(existing.alertID),
          ],
          operation: "alert_coalesce"
        )
        return WorkspaceAlertRecordingResult(
          disposition: .coalesced,
          alert: try requiredAlert(id: existing.alertID)
        )
      }

      let alertID = UUID().uuidString.lowercased()
      let encodedSources = try encodeAlertSources(sourceIDs, alertID: alertID)
      try executePrepared(
        """
        INSERT INTO workspace_alerts(
          alert_id, severity, title, body, source_event_ids_json, deduplication_key,
          cooldown_until, occurrence_count, rule_id, acknowledged_at, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        values: [
          .text(alertID), .text(severity.rawValue), .text(title),
          bodyToStore.map(SQLiteValue.text) ?? .null, .blob(encodedSources), .text(key),
          .double(cooldownUntil.timeIntervalSince1970), .int64(1),
          ruleID.map(SQLiteValue.text) ?? .null, .null,
          .double(now.timeIntervalSince1970), .double(now.timeIntervalSince1970),
        ],
        operation: "alert_insert"
      )
      return WorkspaceAlertRecordingResult(
        disposition: .created,
        alert: try requiredAlert(id: alertID)
      )
    }
  }

  func alert(id: String) throws -> WorkspaceAlert? {
    let identifier = try normalizedRequired(id, field: "alert.id")
    return try loadAlert(id: identifier)
  }

  func alerts(
    includeAcknowledged: Bool = true,
    severities: Set<MessageRuleAlertSeverity> = [],
    limit: Int = 100
  ) throws -> [WorkspaceAlert] {
    guard (1...500).contains(limit) else {
      throw WorkspaceStoreError.invalidArgument("alert.limit")
    }
    var clauses: [String] = []
    var values: [SQLiteValue] = []
    if !includeAcknowledged {
      clauses.append("acknowledged_at IS NULL")
    }
    if !severities.isEmpty {
      let ordered = severities.sorted { $0.rawValue < $1.rawValue }
      clauses.append("severity IN (\(Self.placeholders(count: ordered.count)))")
      values.append(contentsOf: ordered.map { .text($0.rawValue) })
    }
    let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
    values.append(.int64(Int64(limit)))

    let statement = try prepare(
      """
      SELECT \(Self.alertSelectColumns)
      FROM workspace_alerts
      \(whereClause)
      ORDER BY acknowledged_at IS NOT NULL ASC, created_at DESC, alert_id DESC
      LIMIT ?
      """,
      operation: "alert_list"
    )
    defer { sqlite3_finalize(statement) }
    try bind(values, to: statement, operation: "alert_list")
    var alerts: [WorkspaceAlert] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        alerts.append(try decodeAlert(statement))
      case SQLITE_DONE:
        return alerts
      default:
        throw queryError("alert_list")
      }
    }
  }

  @discardableResult
  func acknowledgeAlert(
    id: String,
    acknowledged: Bool = true,
    at date: Date = Date()
  ) throws -> WorkspaceAlert {
    let identifier = try normalizedRequired(id, field: "alert.id")
    return try withTransaction {
      guard try loadAlert(id: identifier) != nil else {
        throw WorkspaceStoreError.alertNotFound(identifier)
      }
      try executePrepared(
        """
        UPDATE workspace_alerts
        SET acknowledged_at = ?, updated_at = ?
        WHERE alert_id = ?
        """,
        values: [
          acknowledged ? .double(date.timeIntervalSince1970) : .null,
          .double(date.timeIntervalSince1970), .text(identifier),
        ],
        operation: "alert_acknowledge"
      )
      return try requiredAlert(id: identifier)
    }
  }

  func deleteAlert(id: String) throws {
    let identifier = try normalizedRequired(id, field: "alert.id")
    try withTransaction {
      guard try loadAlert(id: identifier) != nil else {
        throw WorkspaceStoreError.alertNotFound(identifier)
      }
      try executePrepared(
        "DELETE FROM workspace_alerts WHERE alert_id = ?",
        values: [.text(identifier)],
        operation: "alert_delete"
      )
    }
  }
}

private extension WorkspaceStore {
  static let alertSelectColumns = """
    alert_id, severity, title, body, source_event_ids_json, deduplication_key,
    cooldown_until, occurrence_count, rule_id, acknowledged_at, created_at, updated_at
    """

  static func maximumSeverity(
    _ lhs: MessageRuleAlertSeverity,
    _ rhs: MessageRuleAlertSeverity
  ) -> MessageRuleAlertSeverity {
    func rank(_ severity: MessageRuleAlertSeverity) -> Int {
      switch severity {
      case .information: return 0
      case .warning: return 1
      case .critical: return 2
      }
    }
    return rank(lhs) >= rank(rhs) ? lhs : rhs
  }

  func normalizedSourceEventIDs(_ values: [String]) throws -> [String] {
    guard values.count <= 10_000 else {
      throw WorkspaceStoreError.invalidArgument("alert.sourceEventIDs")
    }
    var result: [String] = []
    var seen = Set<String>()
    for value in values {
      let normalized = try normalizedRequired(value, field: "alert.sourceEventIDs")
      if seen.insert(normalized).inserted { result.append(normalized) }
    }
    return result
  }

  func encodeAlertSources(_ values: [String], alertID: String) throws -> Data {
    do {
      return try Self.makeJSONEncoder().encode(values)
    } catch {
      throw WorkspaceStoreError.alertSourceEncodingFailed(alertID)
    }
  }

  func decodeAlertSources(_ data: Data, alertID: String) throws -> [String] {
    do {
      return try Self.makeJSONDecoder().decode([String].self, from: data)
    } catch {
      throw WorkspaceStoreError.alertSourceDecodingFailed(alertID)
    }
  }

  func alertInCooldown(deduplicationKey: String, now: Date) throws -> WorkspaceAlert? {
    let statement = try prepare(
      """
      SELECT \(Self.alertSelectColumns)
      FROM workspace_alerts
      WHERE deduplication_key = ? AND cooldown_until > ?
      ORDER BY updated_at DESC, alert_id DESC
      LIMIT 1
      """,
      operation: "alert_cooldown"
    )
    defer { sqlite3_finalize(statement) }
    try bind(
      [.text(deduplicationKey), .double(now.timeIntervalSince1970)],
      to: statement,
      operation: "alert_cooldown"
    )
    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      return try decodeAlert(statement)
    case SQLITE_DONE:
      return nil
    default:
      throw queryError("alert_cooldown")
    }
  }

  func loadAlert(id: String) throws -> WorkspaceAlert? {
    let statement = try prepare(
      "SELECT \(Self.alertSelectColumns) FROM workspace_alerts WHERE alert_id = ? LIMIT 1",
      operation: "alert_read"
    )
    defer { sqlite3_finalize(statement) }
    try bind([.text(id)], to: statement, operation: "alert_read")
    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      return try decodeAlert(statement)
    case SQLITE_DONE:
      return nil
    default:
      throw queryError("alert_read")
    }
  }

  func requiredAlert(id: String) throws -> WorkspaceAlert {
    guard let alert = try loadAlert(id: id) else {
      throw WorkspaceStoreError.alertNotFound(id)
    }
    return alert
  }

  func decodeAlert(_ statement: OpaquePointer) throws -> WorkspaceAlert {
    let alertID = requiredText(statement, column: 0)
    guard let severity = MessageRuleAlertSeverity(
      rawValue: requiredText(statement, column: 1)
    ) else {
      throw WorkspaceStoreError.queryFailed(
        operation: "alert_decode",
        reason: "unsupported_severity"
      )
    }
    return WorkspaceAlert(
      alertID: alertID,
      severity: severity,
      title: requiredText(statement, column: 2),
      body: optionalText(statement, column: 3),
      sourceEventIDs: try decodeAlertSources(
        requiredData(statement, column: 4),
        alertID: alertID
      ),
      deduplicationKey: requiredText(statement, column: 5),
      cooldownUntil: optionalDate(statement, column: 6),
      occurrenceCount: Int(sqlite3_column_int64(statement, 7)),
      ruleID: optionalText(statement, column: 8),
      acknowledgedAt: optionalDate(statement, column: 9),
      createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
      updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11))
    )
  }
}

// MARK: - Cross-group crypto addresses

public extension WorkspaceStore {
  @discardableResult
  func recordCryptoAddressMention(
    _ match: CryptoAddressMatch,
    event: MessageEvent,
    triggerSnapshot: CATokenMarketSnapshot? = nil,
    now: Date = Date()
  ) throws -> CryptoAddressMentionRecordingResult {
    let eventID = try normalizedRequired(event.eventID, field: "addressMention.eventID")
    let groupName = try normalizedRequired(event.group, field: "addressMention.groupName")
    let originalAddress = try normalizedRequired(match.address, field: "addressMention.address")
    let normalizedAddress = try normalizedRequired(
      match.family == .evm ? match.normalizedAddress.lowercased() : match.normalizedAddress,
      field: "addressMention.normalizedAddress"
    )
    let network = match.network
    guard originalAddress.count <= 128, normalizedAddress.count <= 128 else {
      throw WorkspaceStoreError.invalidArgument("addressMention.address")
    }
    guard event.observedAt.timeIntervalSince1970.isFinite,
      now.timeIntervalSince1970.isFinite
    else {
      throw WorkspaceStoreError.invalidArgument("addressMention.date")
    }
    let senderKey = try normalizedAddressSenderKey(for: event)

    return try withTransaction {
      try executePrepared(
        """
        INSERT OR IGNORE INTO crypto_address_mentions(
          event_id, family, network, normalized_address, original_address, group_name,
          sender_key, observed_at, detector_version, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        values: [
          .text(eventID), .text(match.family.rawValue), .text(network.rawValue), .text(normalizedAddress),
          .text(originalAddress), .text(groupName),
          senderKey.map(SQLiteValue.text) ?? .null,
          .double(event.observedAt.timeIntervalSince1970),
          .int64(Int64(CryptoAddressDetector.detectorVersion)),
          .double(now.timeIntervalSince1970),
        ],
        operation: "address_mention_insert"
      )
      guard sqlite3_changes(database) > 0 else {
        return CryptoAddressMentionRecordingResult(disposition: .duplicate)
      }

      let window = Self.crossGroupAddressWindow
      var active = try activeCrossGroupAddressIncident(
        family: match.family,
        network: network,
        normalizedAddress: normalizedAddress
      )
      if let current = active,
        event.observedAt > current.latestSeenAt.addingTimeInterval(window)
      {
        try executePrepared(
          """
          UPDATE crypto_address_incidents
          SET status = ?, updated_at = ?
          WHERE incident_id = ?
          """,
          values: [
            .text(CrossGroupAddressIncidentStatus.closed.rawValue),
            .double(now.timeIntervalSince1970), .text(current.incidentID),
          ],
          operation: "address_incident_close"
        )
        active = nil
      }

      if let active {
        let aggregate = try addressMentionAggregate(
          family: match.family,
          network: network,
          normalizedAddress: normalizedAddress,
          start: min(active.firstSeenAt, event.observedAt),
          end: max(active.latestSeenAt, event.observedAt)
        )
        let incident = try updateCrossGroupAddressIncident(
          active,
          aggregate: aggregate,
          triggerSnapshot: triggerSnapshot,
          now: now
        )
        return CryptoAddressMentionRecordingResult(
          disposition: .incidentUpdated,
          incident: incident,
          alert: try requiredAlert(id: incident.alertID)
        )
      }

      let aggregate = try addressMentionAggregate(
        family: match.family,
        network: network,
        normalizedAddress: normalizedAddress,
        start: event.observedAt.addingTimeInterval(-window),
        end: event.observedAt
      )
      guard aggregate.groupNames.count >= 2 else {
        return CryptoAddressMentionRecordingResult(disposition: .recorded)
      }
      let incident = try createCrossGroupAddressIncident(
        family: match.family,
        network: network,
        normalizedAddress: normalizedAddress,
        aggregate: aggregate,
        triggerSnapshot: triggerSnapshot,
        now: now
      )
      return CryptoAddressMentionRecordingResult(
        disposition: .incidentCreated,
        incident: incident,
        alert: try requiredAlert(id: incident.alertID)
      )
    }
  }

  func crossGroupAddressIncidents(limit: Int = 200) throws -> [CrossGroupAddressIncident] {
    guard (1...500).contains(limit) else {
      throw WorkspaceStoreError.invalidArgument("addressIncident.limit")
    }
    let statement = try prepare(
      """
      SELECT \(Self.crossGroupAddressIncidentSelectColumns)
      FROM crypto_address_incidents
      ORDER BY latest_seen_at DESC, incident_id DESC
      LIMIT ?
      """,
      operation: "address_incident_list"
    )
    defer { sqlite3_finalize(statement) }
    try bind([.int64(Int64(limit))], to: statement, operation: "address_incident_list")
    var incidents: [CrossGroupAddressIncident] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        incidents.append(try decodeCrossGroupAddressIncident(statement))
      case SQLITE_DONE:
        return incidents
      default:
        throw queryError("address_incident_list")
      }
    }
  }

  func cryptoAddressMentionSummary(
    family: CryptoAddressFamily,
    network: CryptoAddressNetwork? = nil,
    normalizedAddress rawAddress: String,
    start: Date,
    end: Date
  ) throws -> CryptoAddressMentionSummary? {
    guard start.timeIntervalSince1970.isFinite,
      end.timeIntervalSince1970.isFinite,
      start <= end
    else {
      throw WorkspaceStoreError.invalidArgument("addressMentionSummary.dateRange")
    }
    let requiredAddress = try normalizedRequired(
      rawAddress,
      field: "addressMentionSummary.normalizedAddress"
    )
    let normalizedAddress = family == .evm ? requiredAddress.lowercased() : requiredAddress
    let resolvedNetwork = network ?? (family == .solana ? .solana : .evm)
    guard normalizedAddress.count <= 128 else {
      throw WorkspaceStoreError.invalidArgument("addressMentionSummary.normalizedAddress")
    }

    let aggregate: AddressMentionAggregate
    do {
      aggregate = try addressMentionAggregate(
        family: family,
        network: resolvedNetwork,
        normalizedAddress: normalizedAddress,
        start: start,
        end: end
      )
    } catch WorkspaceStoreError.queryFailed(let operation, let reason)
      where operation == "address_mention_window" && reason == "empty_window"
    {
      return nil
    }

    return CryptoAddressMentionSummary(
      family: family,
      network: resolvedNetwork,
      normalizedAddress: normalizedAddress,
      originalAddress: aggregate.originalAddress,
      firstSeenAt: aggregate.firstSeenAt,
      latestSeenAt: aggregate.latestSeenAt,
      mentionCount: aggregate.mentionCount,
      groupNames: aggregate.groupNames
    )
  }
}

private extension WorkspaceStore {
  struct AddressMentionAggregate {
    let originalAddress: String
    let firstSeenAt: Date
    let latestSeenAt: Date
    let mentionCount: Int
    let groupNames: [String]
    let sourceEventIDs: [String]
  }

  static let crossGroupAddressIncidentSelectColumns = """
    incident_id, family, network, normalized_address, original_address,
    first_seen_at, latest_seen_at, mention_count, group_names_json,
    source_event_ids_json, alert_id, status, created_at, updated_at
    """

  func normalizedAddressSenderKey(for event: MessageEvent) throws -> String? {
    if let stableID = event.senderStableID?.trimmingCharacters(in: .whitespacesAndNewlines),
      !stableID.isEmpty
    {
      let value = try normalizedRequired(stableID, field: "addressMention.senderStableID")
      return String("id:\(value)".prefix(1_024))
    }
    if let displayName = event.senderDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
      !displayName.isEmpty
    {
      let value = try normalizedRequired(displayName, field: "addressMention.senderDisplayName")
      return String("name:\(value)".prefix(1_024))
    }
    return nil
  }

  func addressMentionAggregate(
    family: CryptoAddressFamily,
    network: CryptoAddressNetwork,
    normalizedAddress: String,
    start: Date,
    end: Date
  ) throws -> AddressMentionAggregate {
    let statement = try prepare(
      """
      SELECT event_id, original_address, group_name, observed_at
      FROM crypto_address_mentions
      WHERE family = ? AND network = ? AND normalized_address = ?
        AND observed_at >= ? AND observed_at <= ?
      ORDER BY observed_at ASC, event_id ASC
      """,
      operation: "address_mention_window"
    )
    defer { sqlite3_finalize(statement) }
    try bind(
      [
        .text(family.rawValue), .text(network.rawValue), .text(normalizedAddress),
        .double(start.timeIntervalSince1970), .double(end.timeIntervalSince1970),
      ],
      to: statement,
      operation: "address_mention_window"
    )

    var originalAddress = normalizedAddress
    var firstSeenAt: Date?
    var latestSeenAt: Date?
    var mentionCount = 0
    var groupNames: [String] = []
    var seenGroups = Set<String>()
    var sourceEventIDs: [String] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        let observedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
        if firstSeenAt == nil {
          firstSeenAt = observedAt
          originalAddress = requiredText(statement, column: 1)
        }
        latestSeenAt = observedAt
        mentionCount += 1
        let group = requiredText(statement, column: 2)
        if seenGroups.insert(group).inserted { groupNames.append(group) }
        if sourceEventIDs.count < 10_000 {
          sourceEventIDs.append(requiredText(statement, column: 0))
        }
      case SQLITE_DONE:
        guard let firstSeenAt, let latestSeenAt else {
          throw WorkspaceStoreError.queryFailed(
            operation: "address_mention_window",
            reason: "empty_window"
          )
        }
        return AddressMentionAggregate(
          originalAddress: originalAddress,
          firstSeenAt: firstSeenAt,
          latestSeenAt: latestSeenAt,
          mentionCount: mentionCount,
          groupNames: groupNames,
          sourceEventIDs: sourceEventIDs
        )
      default:
        throw queryError("address_mention_window")
      }
    }
  }

  func activeCrossGroupAddressIncident(
    family: CryptoAddressFamily,
    network: CryptoAddressNetwork,
    normalizedAddress: String
  ) throws -> CrossGroupAddressIncident? {
    let statement = try prepare(
      """
      SELECT \(Self.crossGroupAddressIncidentSelectColumns)
      FROM crypto_address_incidents
      WHERE family = ? AND network = ? AND normalized_address = ? AND status = ?
      ORDER BY latest_seen_at DESC, incident_id DESC
      LIMIT 1
      """,
      operation: "address_incident_active"
    )
    defer { sqlite3_finalize(statement) }
    try bind(
      [
        .text(family.rawValue), .text(network.rawValue), .text(normalizedAddress),
        .text(CrossGroupAddressIncidentStatus.active.rawValue),
      ],
      to: statement,
      operation: "address_incident_active"
    )
    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      return try decodeCrossGroupAddressIncident(statement)
    case SQLITE_DONE:
      return nil
    default:
      throw queryError("address_incident_active")
    }
  }

  func createCrossGroupAddressIncident(
    family: CryptoAddressFamily,
    network: CryptoAddressNetwork,
    normalizedAddress: String,
    aggregate: AddressMentionAggregate,
    triggerSnapshot: CATokenMarketSnapshot?,
    now: Date
  ) throws -> CrossGroupAddressIncident {
    let incidentID = UUID().uuidString.lowercased()
    let alertID = UUID().uuidString.lowercased()
    let severity = crossGroupAddressSeverity(groupCount: aggregate.groupNames.count)
    let encodedGroups = try encodeAddressIncidentStrings(
      aggregate.groupNames,
      operation: "address_incident_groups_encode"
    )
    let encodedSources = try encodeAlertSources(aggregate.sourceEventIDs, alertID: alertID)
    let presentation = crossGroupAddressPresentation(
      family: family,
      network: network,
      normalizedAddress: normalizedAddress,
      groupNames: aggregate.groupNames,
      mentionCount: aggregate.mentionCount,
      triggerSnapshot: triggerSnapshot
    )
    try executePrepared(
      """
      INSERT INTO workspace_alerts(
        alert_id, severity, title, body, source_event_ids_json, deduplication_key,
        cooldown_until, occurrence_count, rule_id, acknowledged_at, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      values: [
        .text(alertID), .text(severity.rawValue), .text(presentation.title),
        .text(presentation.body), .blob(encodedSources),
        .text("cross-group-address:v1:\(incidentID)"),
        .double(aggregate.latestSeenAt.addingTimeInterval(Self.crossGroupAddressWindow).timeIntervalSince1970),
        .int64(Int64(aggregate.mentionCount)), .null, .null,
        .double(now.timeIntervalSince1970), .double(now.timeIntervalSince1970),
      ],
      operation: "address_alert_insert"
    )
    try executePrepared(
      """
      INSERT INTO crypto_address_incidents(
        incident_id, family, network, normalized_address, original_address,
        first_seen_at, latest_seen_at, mention_count, group_names_json,
        source_event_ids_json, alert_id, status, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      values: [
        .text(incidentID), .text(family.rawValue), .text(network.rawValue), .text(normalizedAddress),
        .text(aggregate.originalAddress), .double(aggregate.firstSeenAt.timeIntervalSince1970),
        .double(aggregate.latestSeenAt.timeIntervalSince1970),
        .int64(Int64(aggregate.mentionCount)), .blob(encodedGroups), .blob(encodedSources),
        .text(alertID), .text(CrossGroupAddressIncidentStatus.active.rawValue),
        .double(now.timeIntervalSince1970), .double(now.timeIntervalSince1970),
      ],
      operation: "address_incident_insert"
    )
    return try requiredCrossGroupAddressIncident(id: incidentID)
  }

  func updateCrossGroupAddressIncident(
    _ incident: CrossGroupAddressIncident,
    aggregate: AddressMentionAggregate,
    triggerSnapshot: CATokenMarketSnapshot?,
    now: Date
  ) throws -> CrossGroupAddressIncident {
    let severity = crossGroupAddressSeverity(groupCount: aggregate.groupNames.count)
    let encodedGroups = try encodeAddressIncidentStrings(
      aggregate.groupNames,
      operation: "address_incident_groups_encode"
    )
    let encodedSources = try encodeAlertSources(
      aggregate.sourceEventIDs,
      alertID: incident.alertID
    )
    let presentation = crossGroupAddressPresentation(
      family: incident.family,
      network: incident.network,
      normalizedAddress: incident.normalizedAddress,
      groupNames: aggregate.groupNames,
      mentionCount: aggregate.mentionCount,
      triggerSnapshot: triggerSnapshot
    )
    try executePrepared(
      """
      UPDATE crypto_address_incidents
      SET original_address = ?, first_seen_at = ?, latest_seen_at = ?, mention_count = ?,
          group_names_json = ?, source_event_ids_json = ?, status = ?, updated_at = ?
      WHERE incident_id = ?
      """,
      values: [
        .text(aggregate.originalAddress), .double(aggregate.firstSeenAt.timeIntervalSince1970),
        .double(aggregate.latestSeenAt.timeIntervalSince1970),
        .int64(Int64(aggregate.mentionCount)), .blob(encodedGroups), .blob(encodedSources),
        .text(CrossGroupAddressIncidentStatus.active.rawValue),
        .double(now.timeIntervalSince1970), .text(incident.incidentID),
      ],
      operation: "address_incident_update"
    )
    try executePrepared(
      """
      UPDATE workspace_alerts
      SET severity = ?, title = ?, body = ?, source_event_ids_json = ?,
          cooldown_until = ?, occurrence_count = ?, acknowledged_at = NULL, updated_at = ?
      WHERE alert_id = ?
      """,
      values: [
        .text(severity.rawValue), .text(presentation.title), .text(presentation.body),
        .blob(encodedSources),
        .double(aggregate.latestSeenAt.addingTimeInterval(Self.crossGroupAddressWindow).timeIntervalSince1970),
        .int64(Int64(aggregate.mentionCount)), .double(now.timeIntervalSince1970),
        .text(incident.alertID),
      ],
      operation: "address_alert_update"
    )
    return try requiredCrossGroupAddressIncident(id: incident.incidentID)
  }

  func crossGroupAddressSeverity(groupCount: Int) -> MessageRuleAlertSeverity {
    groupCount >= 3 ? .warning : .information
  }

  func crossGroupAddressPresentation(
    family: CryptoAddressFamily,
    network: CryptoAddressNetwork? = nil,
    normalizedAddress: String,
    groupNames: [String],
    mentionCount: Int,
    triggerSnapshot: CATokenMarketSnapshot?
  ) -> (title: String, body: String) {
    let familyName: String
    if family == .solana || network == .solana {
      familyName = "Solana 地址"
    } else if let network {
      familyName = "0x 地址（\(network.displayName)）"
    } else {
      familyName = "0x 地址（网络待识别）"
    }
    let abbreviated: String
    if normalizedAddress.count > 16 {
      abbreviated = "\(normalizedAddress.prefix(8))…\(normalizedAddress.suffix(6))"
    } else {
      abbreviated = normalizedAddress
    }
    let visibleGroups = groupNames.prefix(8).joined(separator: "、")
    let remaining = max(0, groupNames.count - 8)
    let groupSuffix = remaining > 0 ? " 等 \(groupNames.count) 个群" : ""
    let identity: String
    let market: String
    if let triggerSnapshot {
      identity = "\(crossGroupTokenTitle(triggerSnapshot)) · \(triggerSnapshot.chain.localizedTitle)"
      market = triggerSnapshot.marketCapUSD.map {
        "触发时市值 \(compactMarketCapUSD($0))"
      } ?? "触发时市值未返回"
    } else {
      identity = familyName
      market = "触发时市值待识别"
    }
    return (
      "跨群 CA · \(triggerSnapshot.map(crossGroupTokenTitle) ?? abbreviated)",
      "\(identity) · \(market) · \(groupNames.count) 个已采集群 · \(mentionCount) 次提及 · \(visibleGroups)\(groupSuffix)"
    )
  }

  func crossGroupTokenTitle(_ snapshot: CATokenMarketSnapshot) -> String {
    if !snapshot.symbol.isEmpty, !snapshot.name.isEmpty,
      snapshot.symbol.caseInsensitiveCompare(snapshot.name) != .orderedSame
    {
      return "\(snapshot.symbol) · \(snapshot.name)"
    }
    if !snapshot.symbol.isEmpty { return snapshot.symbol }
    if !snapshot.name.isEmpty { return snapshot.name }
    return "未知代币"
  }

  func compactMarketCapUSD(_ value: Double) -> String {
    guard value.isFinite, value >= 0 else { return "未返回" }
    let number: Double
    let suffix: String
    if value >= 1_000_000_000 {
      number = value / 1_000_000_000
      suffix = "B"
    } else if value >= 1_000_000 {
      number = value / 1_000_000
      suffix = "M"
    } else if value >= 1_000 {
      number = value / 1_000
      suffix = "K"
    } else {
      number = value
      suffix = ""
    }
    return "$" + number.formatted(
      .number.locale(Locale(identifier: "en_US_POSIX")).precision(.fractionLength(0...1))
    ) + suffix
  }

  func encodeAddressIncidentStrings(_ values: [String], operation: String) throws -> Data {
    do {
      return try Self.makeJSONEncoder().encode(values)
    } catch {
      throw WorkspaceStoreError.queryFailed(operation: operation, reason: "json_encode_failed")
    }
  }

  func decodeAddressIncidentStrings(_ data: Data, operation: String) throws -> [String] {
    do {
      return try Self.makeJSONDecoder().decode([String].self, from: data)
    } catch {
      throw WorkspaceStoreError.queryFailed(operation: operation, reason: "json_decode_failed")
    }
  }

  func requiredCrossGroupAddressIncident(id: String) throws -> CrossGroupAddressIncident {
    let statement = try prepare(
      """
      SELECT \(Self.crossGroupAddressIncidentSelectColumns)
      FROM crypto_address_incidents
      WHERE incident_id = ?
      LIMIT 1
      """,
      operation: "address_incident_read"
    )
    defer { sqlite3_finalize(statement) }
    try bind([.text(id)], to: statement, operation: "address_incident_read")
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw queryError("address_incident_read")
    }
    return try decodeCrossGroupAddressIncident(statement)
  }

  func decodeCrossGroupAddressIncident(
    _ statement: OpaquePointer
  ) throws -> CrossGroupAddressIncident {
    guard let family = CryptoAddressFamily(rawValue: requiredText(statement, column: 1)),
      let status = CrossGroupAddressIncidentStatus(rawValue: requiredText(statement, column: 11))
    else {
      throw WorkspaceStoreError.queryFailed(
        operation: "address_incident_decode",
        reason: "unsupported_enum"
      )
    }
    return CrossGroupAddressIncident(
      incidentID: requiredText(statement, column: 0),
      family: family,
      network: CryptoAddressNetwork(rawValue: requiredText(statement, column: 2)),
      normalizedAddress: requiredText(statement, column: 3),
      originalAddress: requiredText(statement, column: 4),
      firstSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
      latestSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
      mentionCount: Int(sqlite3_column_int64(statement, 7)),
      groupNames: try decodeAddressIncidentStrings(
        requiredData(statement, column: 8),
        operation: "address_incident_groups_decode"
      ),
      sourceEventIDs: try decodeAddressIncidentStrings(
        requiredData(statement, column: 9),
        operation: "address_incident_sources_decode"
      ),
      alertID: requiredText(statement, column: 10),
      status: status,
      createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12)),
      updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 13))
    )
  }
}
