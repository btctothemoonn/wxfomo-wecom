import Darwin
import Dispatch
import Foundation

private final class NotificationWakeSource {
  private let directoryFD: Int32
  private let fileFD: Int32
  private let walFD: Int32
  private let pollInterval: TimeInterval
  private var fileSource: DispatchSourceFileSystemObject?
  private var walSource: DispatchSourceFileSystemObject?
  private var directorySource: DispatchSourceFileSystemObject?
  private var timerSource: DispatchSourceTimer?

  init(databaseURL: URL, pollInterval: TimeInterval) throws {
    let directoryURL = databaseURL.deletingLastPathComponent()
    let directoryFD = open(directoryURL.path, O_EVTONLY)
    guard directoryFD >= 0 else {
      throw NotificationDatabaseError.databaseUnreadable(directoryURL.path)
    }
    self.directoryFD = directoryFD
    // 同时监听 db 文件本身（SQLite WAL 写入不会改变目录条目）；
    // 被 TCC 拒绝或文件暂缺时退化为仅靠目录事件与定时补扫。
    self.fileFD = open(databaseURL.path, O_EVTONLY)
    self.walFD = open(databaseURL.path + "-wal", O_EVTONLY)
    self.pollInterval = pollInterval
  }

  func events() -> AsyncStream<Void> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let queue = DispatchQueue(label: "com.wxfomo.notification-db-wake-source")
      let fileDescriptor = self.fileFD
      let walDescriptor = self.walFD

      let directorySource = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: self.directoryFD,
        eventMask: [.write, .rename, .delete, .attrib],
        queue: queue
      )
      let timerSource = DispatchSource.makeTimerSource(queue: queue)
      self.directorySource = directorySource
      self.timerSource = timerSource

      directorySource.setEventHandler {
        continuation.yield()
      }
      directorySource.setCancelHandler { [directoryFD = self.directoryFD] in
        close(directoryFD)
      }
      timerSource.setEventHandler {
        continuation.yield()
      }

      let fileSource: DispatchSourceFileSystemObject?
      if fileDescriptor >= 0 {
        let source = DispatchSource.makeFileSystemObjectSource(
          fileDescriptor: fileDescriptor,
          eventMask: [.write, .extend, .attrib],
          queue: queue
        )
        source.setEventHandler {
          continuation.yield()
        }
        source.setCancelHandler {
          close(fileDescriptor)
        }
        fileSource = source
        self.fileSource = source
      } else {
        fileSource = nil
      }

      let walSource: DispatchSourceFileSystemObject?
      if walDescriptor >= 0 {
        let source = DispatchSource.makeFileSystemObjectSource(
          fileDescriptor: walDescriptor,
          eventMask: [.write, .extend, .rename, .delete, .attrib],
          queue: queue
        )
        source.setEventHandler {
          continuation.yield()
        }
        source.setCancelHandler {
          close(walDescriptor)
        }
        walSource = source
        self.walSource = source
      } else {
        walSource = nil
      }

      timerSource.schedule(
        deadline: .now() + pollInterval,
        repeating: pollInterval,
        leeway: .milliseconds(100)
      )
      continuation.onTermination = {
        [weak fileSource, weak walSource, weak directorySource, weak timerSource] _ in
        fileSource?.cancel()
        walSource?.cancel()
        directorySource?.cancel()
        timerSource?.cancel()
      }
      directorySource.resume()
      fileSource?.resume()
      walSource?.resume()
      timerSource.resume()
    }
  }

  deinit {
    fileSource?.cancel()
    walSource?.cancel()
    directorySource?.cancel()
    timerSource?.cancel()
  }
}

public final class WeChatNotificationMonitor {
  public typealias EventSink = (MessageEvent) -> Void
  public typealias LogSink = (String) -> Void
  public typealias HealthSink = (NotificationMonitorHealth) -> Void

  private let reader: NotificationRecordReading
  private let mapper: NotificationMapper
  private let groups: [String]
  private let includeExisting: Bool
  private let pollInterval: TimeInterval
  private let recentSweepInterval: TimeInterval
  private let recentSweepLimit: Int
  private let watchesFileSystem: Bool
  private let onEvent: EventSink
  private let onLog: LogSink
  private let onHealth: HealthSink
  private var emittedEventIDs = Set<String>()
  private var emittedEventIDOrder: [String] = []
  private let emittedEventIDLimit = 10_000
  private var observedRecordFingerprints = Set<String>()
  private var observedRecordFingerprintOrder: [String] = []
  private let observedRecordFingerprintLimit = 10_000

  public init(
    reader: NotificationRecordReading = NotificationDatabaseReader(),
    mapper: NotificationMapper = NotificationMapper(),
    groups: [String],
    includeExisting: Bool = false,
    pollInterval: TimeInterval = 0.1,
    recentSweepInterval: TimeInterval = 0.1,
    recentSweepLimit: Int = 100,
    watchesFileSystem: Bool = true,
    onEvent: @escaping EventSink,
    onLog: @escaping LogSink = { _ in },
    onHealth: @escaping HealthSink = { _ in }
  ) {
    self.reader = reader
    self.mapper = mapper
    self.groups = groups
    self.includeExisting = includeExisting
    self.pollInterval = max(0.05, pollInterval)
    self.recentSweepInterval = max(0.05, recentSweepInterval)
    self.recentSweepLimit = max(1, min(recentSweepLimit, 500))
    self.watchesFileSystem = watchesFileSystem
    self.onEvent = onEvent
    self.onLog = onLog
    self.onHealth = onHealth
  }

  public func run() async throws {
    guard !groups.isEmpty else { throw MonitorError.noGroups }
    let startedAt = Date()
    var currentSourceIdentity = reader.sourceIdentity
    var lastRowID = try reader.latestRowID()
    var scannedRecordCount = 0
    var identifiedWeChatNotificationCount = 0
    var decodedNotificationCount = 0
    var groupMatchedNotificationCount = 0
    var unmatchedGroupNotificationCount = 0
    var matchedEventCount = 0
    var updatedNotificationRecoveryCount = 0
    var recoveryCount = 0
    var databaseResetCount = 0
    var lastSuccessfulScanAt: Date? = startedAt
    var lastDatabaseActivityAt: Date?
    var latestActivity = NotificationFlowActivity.waitingForNewRecords
    var hadScanFailure = false
    var lastRecentSweepAt = startedAt
    var hasRecentBaseline = false

    do {
      let baselineRecords = try reader.recentRecords(limit: recentSweepLimit)
      for record in baselineRecords {
        rememberRecord(record)
        guard let event = mapper.event(from: record, groups: groups) else { continue }
        if includeExisting {
          if emitIfNew(event) { matchedEventCount += 1 }
        } else {
          remember(event)
        }
      }
      hasRecentBaseline = true
    } catch {
      onLog("通知尾部基线暂时不可读；增量监听继续，稍后会自动重试尾部基线")
    }

    onHealth(
      health(
        startedAt: startedAt,
        lastSuccessfulScanAt: lastSuccessfulScanAt,
        lastDatabaseActivityAt: lastDatabaseActivityAt,
        latestActivity: latestActivity,
        lastRowID: lastRowID,
        scannedRecordCount: scannedRecordCount,
        identifiedWeChatNotificationCount: identifiedWeChatNotificationCount,
        decodedNotificationCount: decodedNotificationCount,
        groupMatchedNotificationCount: groupMatchedNotificationCount,
        unmatchedGroupNotificationCount: unmatchedGroupNotificationCount,
        matchedEventCount: matchedEventCount,
        updatedNotificationRecoveryCount: updatedNotificationRecoveryCount,
        recoveryCount: recoveryCount,
        databaseResetCount: databaseResetCount,
        lastError: nil
      ))
    onLog("通知通道已启动；基线 rowid=\(lastRowID)，文件事件与定时补扫均已启用")

    let events: AsyncStream<Void>
    var wakeSource: NotificationWakeSource?
    if watchesFileSystem {
      let source = try NotificationWakeSource(
        databaseURL: reader.databaseURL,
        pollInterval: pollInterval
      )
      wakeSource = source
      events = source.events()
    } else {
      events = timerEvents(interval: pollInterval)
    }

    for await _ in events {
      if Task.isCancelled { break }
      do {
        if let observedSourceIdentity = reader.sourceIdentity {
          if let currentSourceIdentity = currentSourceIdentity,
            observedSourceIdentity != currentSourceIdentity
          {
            databaseResetCount += 1
            lastRowID = 0
            hasRecentBaseline = false
            onLog("通知数据库来源已更换，已从新数据库起点补扫")
          }
          currentSourceIdentity = observedSourceIdentity
        }
        let latestRowID = try reader.latestRowID()
        if latestRowID < lastRowID {
          databaseResetCount += 1
          lastRowID = 0
          onLog("通知数据库序号回退，已从新数据库起点补扫；可能包含已去重的历史通知")
        }

        while true {
          let batch = try reader.batch(after: lastRowID, limit: 200)
          scannedRecordCount += batch.scannedCount
          identifiedWeChatNotificationCount += batch.weChatRecordCount
          decodedNotificationCount += batch.records.count
          var batchGroupMatchedCount = 0
          for record in batch.records {
            rememberRecord(record)
            if let event = mapper.event(from: record, groups: groups) {
              batchGroupMatchedCount += 1
              if emitIfNew(event) { matchedEventCount += 1 }
            }
          }
          groupMatchedNotificationCount += batchGroupMatchedCount
          unmatchedGroupNotificationCount += batch.records.count - batchGroupMatchedCount
          if batch.scannedCount > 0 {
            lastDatabaseActivityAt = Date()
            latestActivity = activity(
              batch: batch,
              groupMatchedCount: batchGroupMatchedCount
            )
          }
          lastRowID = max(lastRowID, batch.lastScannedRowID)
          if batch.scannedCount < 200 { break }
          if Task.isCancelled { break }
        }

        let sweepAt = Date()
        if sweepAt.timeIntervalSince(lastRecentSweepAt) >= recentSweepInterval {
          lastRecentSweepAt = sweepAt
          var recoveredUpdates = 0
          let recentRecords = try reader.recentRecords(limit: recentSweepLimit)
          if hasRecentBaseline {
            for record in recentRecords {
              guard rememberRecord(record) else { continue }
              scannedRecordCount += 1
              identifiedWeChatNotificationCount += 1
              decodedNotificationCount += 1
              guard let event = mapper.event(from: record, groups: groups) else {
                unmatchedGroupNotificationCount += 1
                latestActivity = .groupNotMonitored
                lastDatabaseActivityAt = sweepAt
                continue
              }
              groupMatchedNotificationCount += 1
              if emitRecoveredUpdate(event) {
                recoveredUpdates += 1
                matchedEventCount += 1
              }
            }
          } else {
            for record in recentRecords {
              rememberRecord(record)
              guard let event = mapper.event(from: record, groups: groups) else { continue }
              if includeExisting {
                if emitIfNew(event) { matchedEventCount += 1 }
              } else {
                remember(event)
              }
            }
            hasRecentBaseline = true
            onLog("通知尾部基线读取已恢复")
          }
          if recoveredUpdates > 0 {
            updatedNotificationRecoveryCount += recoveredUpdates
            lastDatabaseActivityAt = sweepAt
            latestActivity = .matchedGroup
            onLog("尾部补扫捕获 \(recoveredUpdates) 条企业微信短时通知或原地更新")
          }
        }

        lastSuccessfulScanAt = Date()
        if hadScanFailure {
          hadScanFailure = false
          onLog("通知数据库读取已自动恢复")
        }
        onHealth(
          health(
            startedAt: startedAt,
            lastSuccessfulScanAt: lastSuccessfulScanAt,
            lastDatabaseActivityAt: lastDatabaseActivityAt,
            latestActivity: latestActivity,
            lastRowID: lastRowID,
            scannedRecordCount: scannedRecordCount,
            identifiedWeChatNotificationCount: identifiedWeChatNotificationCount,
            decodedNotificationCount: decodedNotificationCount,
            groupMatchedNotificationCount: groupMatchedNotificationCount,
            unmatchedGroupNotificationCount: unmatchedGroupNotificationCount,
            matchedEventCount: matchedEventCount,
            updatedNotificationRecoveryCount: updatedNotificationRecoveryCount,
            recoveryCount: recoveryCount,
            databaseResetCount: databaseResetCount,
            lastError: nil
          ))
      } catch is CancellationError {
        break
      } catch {
        if !hadScanFailure {
          recoveryCount += 1
          hadScanFailure = true
          onLog("通知数据库暂时不可读，监听器会继续自动重试：\(error.localizedDescription)")
        }
        onHealth(
          health(
            startedAt: startedAt,
            lastSuccessfulScanAt: lastSuccessfulScanAt,
            lastDatabaseActivityAt: lastDatabaseActivityAt,
            latestActivity: latestActivity,
            lastRowID: lastRowID,
            scannedRecordCount: scannedRecordCount,
            identifiedWeChatNotificationCount: identifiedWeChatNotificationCount,
            decodedNotificationCount: decodedNotificationCount,
            groupMatchedNotificationCount: groupMatchedNotificationCount,
            unmatchedGroupNotificationCount: unmatchedGroupNotificationCount,
            matchedEventCount: matchedEventCount,
            updatedNotificationRecoveryCount: updatedNotificationRecoveryCount,
            recoveryCount: recoveryCount,
            databaseResetCount: databaseResetCount,
            lastError: error.localizedDescription
          ))
      }
    }
    _ = wakeSource
  }

  private func timerEvents(interval: TimeInterval) -> AsyncStream<Void> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(interval))
          if !Task.isCancelled { continuation.yield() }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  @discardableResult
  private func emitIfNew(_ event: MessageEvent) -> Bool {
    guard remember(event) else { return false }
    onEvent(event)
    return true
  }

  @discardableResult
  private func emitRecoveredUpdate(_ event: MessageEvent) -> Bool {
    _ = remember(event)
    onEvent(event)
    return true
  }

  @discardableResult
  private func remember(_ event: MessageEvent) -> Bool {
    guard emittedEventIDs.insert(event.eventID).inserted else { return false }
    emittedEventIDOrder.append(event.eventID)
    if emittedEventIDOrder.count > emittedEventIDLimit {
      let removeCount = emittedEventIDOrder.count - emittedEventIDLimit
      let removed = Array(emittedEventIDOrder.prefix(removeCount))
      emittedEventIDOrder.removeFirst(removeCount)
      for eventID in removed { emittedEventIDs.remove(eventID) }
    }
    return true
  }

  @discardableResult
  private func rememberRecord(_ record: NotificationRecord) -> Bool {
    let fingerprint = StableHash.notificationRecordFingerprint(record)
    guard observedRecordFingerprints.insert(fingerprint).inserted else { return false }
    observedRecordFingerprintOrder.append(fingerprint)
    if observedRecordFingerprintOrder.count > observedRecordFingerprintLimit {
      let overflow = observedRecordFingerprintOrder.count - observedRecordFingerprintLimit
      for expired in observedRecordFingerprintOrder.prefix(overflow) {
        observedRecordFingerprints.remove(expired)
      }
      observedRecordFingerprintOrder.removeFirst(overflow)
    }
    return true
  }

  private func health(
    startedAt: Date,
    lastSuccessfulScanAt: Date?,
    lastDatabaseActivityAt: Date?,
    latestActivity: NotificationFlowActivity,
    lastRowID: Int64,
    scannedRecordCount: Int,
    identifiedWeChatNotificationCount: Int,
    decodedNotificationCount: Int,
    groupMatchedNotificationCount: Int,
    unmatchedGroupNotificationCount: Int,
    matchedEventCount: Int,
    updatedNotificationRecoveryCount: Int,
    recoveryCount: Int,
    databaseResetCount: Int,
    lastError: String?
  ) -> NotificationMonitorHealth {
    NotificationMonitorHealth(
      startedAt: startedAt,
      lastSuccessfulScanAt: lastSuccessfulScanAt,
      lastDatabaseActivityAt: lastDatabaseActivityAt,
      latestActivity: latestActivity,
      lastRowID: lastRowID,
      scannedRecordCount: scannedRecordCount,
      identifiedWeChatNotificationCount: identifiedWeChatNotificationCount,
      decodedNotificationCount: decodedNotificationCount,
      groupMatchedNotificationCount: groupMatchedNotificationCount,
      unmatchedGroupNotificationCount: unmatchedGroupNotificationCount,
      matchedEventCount: matchedEventCount,
      updatedNotificationRecoveryCount: updatedNotificationRecoveryCount,
      recoveryCount: recoveryCount,
      databaseResetCount: databaseResetCount,
      lastError: lastError
    )
  }

  private func activity(
    batch: NotificationRecordBatch,
    groupMatchedCount: Int
  ) -> NotificationFlowActivity {
    if groupMatchedCount > 0 { return .matchedGroup }
    if !batch.records.isEmpty { return .groupNotMonitored }
    if batch.weChatRecordCount > 0 { return .payloadDecodeFailed }
    return .nonWeChatNotifications
  }
}
