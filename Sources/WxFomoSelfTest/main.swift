import Foundation
import WxFomoCore

private var failures: [String] = []

private func check(
  _ condition: @autoclosure () -> Bool,
  _ message: String,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  if !condition() {
    failures.append("\(file):\(line): \(message)")
  }
}

private func requireMessage(
  _ message: ParsedMessage?,
  _ context: String,
  file: StaticString = #filePath,
  line: UInt = #line
) -> ParsedMessage? {
  if message == nil {
    failures.append("\(file):\(line): \(context) should produce a message")
  }
  return message
}

private final class FakeNotificationReader: NotificationRecordReading {
  let databaseURL = FileManager.default.temporaryDirectory
  var isReadable: Bool { true }

  private let lock = NSLock()
  private var storedRecords: [NotificationRecord]
  private var remainingBatchFailures = 0

  init(records: [NotificationRecord] = []) {
    storedRecords = records
  }

  func replace(records: [NotificationRecord]) {
    lock.withLock { storedRecords = records }
  }

  func append(_ record: NotificationRecord) {
    lock.withLock { storedRecords.append(record) }
  }

  func failNextBatches(_ count: Int) {
    lock.withLock { remainingBatchFailures = max(0, count) }
  }

  func latestRowID() throws -> Int64 {
    lock.withLock { storedRecords.map(\.rowID).max() ?? 0 }
  }

  func recentRecords(limit: Int) throws -> [NotificationRecord] {
    lock.withLock {
      Array(storedRecords.sorted { $0.rowID < $1.rowID }.suffix(max(0, limit)))
    }
  }

  func batch(after rowID: Int64, limit: Int) throws -> NotificationRecordBatch {
    try lock.withLock {
      if remainingBatchFailures > 0 {
        remainingBatchFailures -= 1
        throw NotificationDatabaseError.queryFailed("fixture transient failure")
      }
      let records = Array(
        storedRecords
          .filter { $0.rowID > rowID }
          .sorted { $0.rowID < $1.rowID }
          .prefix(max(1, limit))
      )
      return NotificationRecordBatch(
        records: records,
        lastScannedRowID: records.last?.rowID ?? rowID,
        scannedCount: records.count
      )
    }
  }
}

private final class NotificationMonitorCollector {
  private let lock = NSLock()
  private var storedEvents: [MessageEvent] = []
  private var storedHealth: [NotificationMonitorHealth] = []

  func receive(_ event: MessageEvent) {
    lock.withLock { storedEvents.append(event) }
  }

  func receive(_ health: NotificationMonitorHealth) {
    lock.withLock { storedHealth.append(health) }
  }

  var events: [MessageEvent] {
    lock.withLock { storedEvents }
  }

  var health: [NotificationMonitorHealth] {
    lock.withLock { storedHealth }
  }
}

private func fixtureNotification(
  rowID: Int64,
  uuid: String,
  body: String = "张三：测试消息"
) -> NotificationRecord {
  NotificationRecord(
    rowID: rowID,
    uuid: uuid,
    deliveredAt: Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + rowID)),
    title: "测试群",
    subtitle: "张三",
    body: body,
    identifier: uuid
  )
}

private func fixtureMessageEvent(
  id: String,
  group: String = "测试群",
  sender: String? = "张三",
  senderStableID: String? = nil,
  content: String,
  messageType: MessageKind = .text,
  observedAt: Date,
  sequence: Int64
) -> MessageEvent {
  MessageEvent(
    eventID: id,
    group: group,
    senderDisplayName: sender,
    senderStableID: senderStableID,
    content: content,
    messageType: messageType,
    observedAt: observedAt,
    sourceSequence: sequence,
    senderConfidence: sender == nil ? .unavailable : .notificationPayload,
    isFromSelf: false
  )
}

private final class SelfTestAICredentialStore: AICredentialStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var keys: [String: String] = [:]

  func storeAPIKey(_ apiKey: String, for configuration: AIProviderConfiguration) throws {
    lock.withLock { keys[configuration.configurationID] = apiKey }
  }

  func apiKey(for configuration: AIProviderConfiguration) throws -> String {
    try lock.withLock {
      guard let key = keys[configuration.configurationID] else {
        throw AICredentialStoreError.credentialNotFound
      }
      return key
    }
  }

  func deleteAPIKey(for configuration: AIProviderConfiguration) throws {
    _ = lock.withLock { keys.removeValue(forKey: configuration.configurationID) }
  }
}

private final class SelfTestAIHTTPTransport: AIHTTPTransporting, @unchecked Sendable {
  private let lock = NSLock()
  private let response: AIHTTPResponse
  private let delayNanoseconds: UInt64
  private var storedRequest: URLRequest?
  private var storedRequestCount = 0

  init(response: AIHTTPResponse, delayNanoseconds: UInt64 = 0) {
    self.response = response
    self.delayNanoseconds = delayNanoseconds
  }

  func send(_ request: URLRequest) async throws -> AIHTTPResponse {
    lock.withLock {
      storedRequest = request
      storedRequestCount += 1
    }
    if delayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: delayNanoseconds)
    }
    return response
  }

  var lastRequest: URLRequest? {
    lock.withLock { storedRequest }
  }

  var requestCount: Int {
    lock.withLock { storedRequestCount }
  }
}

private enum SelfTestAnalysisProviderBehavior: Sendable {
  case succeed
  case retryableFailure
}

private struct SelfTestAnalysisProvider: AIAnalysisProviding, Sendable {
  let configuration: AIProviderConfiguration
  let behavior: SelfTestAnalysisProviderBehavior

  func analyze(_ request: AIAnalysisRequest) async throws -> AIAnalysisResult {
    switch behavior {
    case .retryableFailure:
      throw AIProviderError.transport(
        AITransportError(kind: .timedOut, isRetryable: true)
      )
    case .succeed:
      let sourceIDs = request.messages.map(\.messageID)
      return AIAnalysisResult(
        analysisID: "selftest-analysis-\(request.requestID)",
        requestID: request.requestID,
        summary: "Self-test summary",
        summarySourceMessageIDs: sourceIDs,
        topics: [],
        findings: [],
        usage: nil,
        provenance: AIAnalysisProvenance(
          providerConfigurationID: configuration.configurationID,
          providerKind: configuration.kind,
          model: configuration.model,
          remoteRequestID: nil,
          remoteResponseID: nil,
          sourceMessageIDs: sourceIDs,
          requestSchemaVersion: request.schemaVersion,
          resultSchemaVersion: AIAnalysisResult.currentSchemaVersion,
          generatedAt: request.createdAt
        ),
        validationWarnings: []
      )
    }
  }
}

private struct SelfTestAnalysisProviderFactory: AIAnalysisProviderFactory, Sendable {
  let behavior: SelfTestAnalysisProviderBehavior

  func makeProvider(
    configuration: AIProviderConfiguration
  ) throws -> any AIAnalysisProviding {
    SelfTestAnalysisProvider(configuration: configuration, behavior: behavior)
  }
}

private actor SelfTestAnalysisRunnerClock: AnalysisJobRunnerClock {
  private var currentDate: Date

  init(now: Date) {
    currentDate = now
  }

  func now() async -> Date { currentDate }

  func sleep(for seconds: TimeInterval) async throws {
    try Task.checkCancellation()
    currentDate = currentDate.addingTimeInterval(max(0, seconds))
  }

  func randomUnitInterval() async -> Double { 0.5 }
}

private func selfTestAnalysisResult(
  job: AIAnalysisJob,
  configuration: AIProviderConfiguration,
  sourceMessageIDs: [String]
) -> AIAnalysisResult {
  AIAnalysisResult(
    analysisID: "selftest-direct-\(job.jobID)",
    requestID: job.jobID,
    summary: "Direct workspace summary",
    summarySourceMessageIDs: sourceMessageIDs,
    topics: [],
    findings: [],
    usage: nil,
    provenance: AIAnalysisProvenance(
      providerConfigurationID: configuration.configurationID,
      providerKind: configuration.kind,
      model: configuration.model,
      remoteRequestID: nil,
      remoteResponseID: nil,
      sourceMessageIDs: sourceMessageIDs,
      requestSchemaVersion: AIAnalysisRequest.currentSchemaVersion,
      resultSchemaVersion: AIAnalysisResult.currentSchemaVersion,
      generatedAt: job.updatedAt
    ),
    validationWarnings: []
  )
}

private func workspaceArtifactsContain(
  _ value: String,
  databaseURL: URL
) throws -> Bool {
  let needle = Data(value.utf8)
  let candidates = [
    databaseURL,
    URL(fileURLWithPath: databaseURL.path + "-wal"),
    URL(fileURLWithPath: databaseURL.path + "-shm"),
    URL(fileURLWithPath: databaseURL.path + ".lock"),
  ]
  for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
    if try Data(contentsOf: candidate).range(of: needle) != nil {
      return true
    }
  }
  return false
}

private func testMessageParser() {
  let parser = MessageParser()

  if let message = requireMessage(
    parser.parse(row: RawMessageRow(labels: ["Alice Said: Ship it"]), group: "Project"),
    "English composite label"
  ) {
    check(message.senderDisplayName == "Alice", "English sender")
    check(message.content == "Ship it", "English content")
    check(message.senderConfidence == .localizedLabel, "English confidence")
  }

  if let message = requireMessage(
    parser.parse(row: RawMessageRow(labels: ["张三说：明天十点开会"]), group: "项目群"),
    "Simplified Chinese composite label"
  ) {
    check(message.senderDisplayName == "张三", "Simplified Chinese sender")
    check(message.content == "明天十点开会", "Simplified Chinese content")
  }

  if let message = requireMessage(
    parser.parse(row: RawMessageRow(labels: ["王小明說：收到"]), group: "工作群"),
    "Traditional Chinese composite label"
  ) {
    check(message.senderDisplayName == "王小明", "Traditional Chinese sender")
    check(message.content == "收到", "Traditional Chinese content")
  }

  if let message = requireMessage(
    parser.parse(row: RawMessageRow(labels: ["李四", "接口已经部署"]), group: "研发群"),
    "Structured fragments"
  ) {
    check(message.senderDisplayName == "李四", "Structured sender")
    check(message.content == "接口已经部署", "Structured content")
    check(message.senderConfidence == .structuredFragments, "Structured confidence")
  }

  if let message = requireMessage(
    parser.parse(
      row: RawMessageRow(labels: ["Alice Said: Hello", "Alice", "Hello"]),
      group: "Project"
    ),
    "Composite label with duplicated fragments"
  ) {
    check(message.senderDisplayName == "Alice", "Composite sender wins")
    check(message.content == "Hello", "Composite content wins")
  }

  if let message = requireMessage(
    parser.parse(row: RawMessageRow(labels: ["Alice: Sent an Image"]), group: "Project"),
    "Media label"
  ) {
    check(message.kind == .media, "Media kind")
    check(message.content == "[Image]", "Media content")
  }

  check(
    parser.parse(row: RawMessageRow(labels: ["21:45"]), group: "项目群") == nil,
    "Timestamp should be ignored"
  )

  if let message = requireMessage(
    parser.parse(row: RawMessageRow(labels: ["一段没有发送者信息的消息"]), group: "项目群"),
    "Unknown single label"
  ) {
    check(message.senderDisplayName == nil, "Unknown label must not invent sender")
    check(message.senderConfidence == .unavailable, "Unknown sender confidence")
  }

  if let message = requireMessage(
    parser.parse(row: RawMessageRow(labels: ["我说：本地记录"]), group: "项目群"),
    "Self message"
  ) {
    check(message.isFromSelf, "Self message flag")
  }
}

private func testSequenceDelta() {
  var result = SequenceDelta.appended(
    previous: ["a", "b"],
    current: ["a", "b", "c"]
  )
  check(result.hadContinuity, "Simple append continuity")
  check(result.newItems == ["c"], "Simple append delta")

  result = SequenceDelta.appended(
    previous: ["a", "b", "c"],
    current: ["b", "c", "d"]
  )
  check(result.hadContinuity, "Scroll continuity")
  check(result.newItems == ["d"], "Scroll delta")

  result = SequenceDelta.appended(previous: ["same"], current: ["same", "same"])
  check(result.hadContinuity, "Repeated message continuity")
  check(result.newItems == ["same"], "Repeated identical message")

  result = SequenceDelta.appended(previous: ["a", "b"], current: ["a", "b"])
  check(result.hadContinuity, "No-change continuity")
  check(result.newItems.isEmpty, "No-change delta")

  result = SequenceDelta.appended(previous: ["a", "b"], current: ["c", "d"])
  check(!result.hadContinuity, "No-overlap continuity")
  check(result.newItems == ["c", "d"], "No-overlap keeps current rows")
}

private func testStableHash() {
  check(StableHash.hex("hello") == StableHash.hex("hello"), "Stable hash determinism")
  check(StableHash.hex("hello") != StableHash.hex("hello!"), "Stable hash input sensitivity")
  check(StableHash.hex("hello").count == 16, "Stable hash length")
}

private func testNotificationPayloadAndMapping() {
  check(
    NotificationDatabaseReader.isWeChatNotificationIdentifier("com.tencent.xinWeChat"),
    "Direct WeChat notification identifier"
  )
  check(
    NotificationDatabaseReader.isWeChatNotificationIdentifier(
      "5A4RE8SF68.com.tencent.xinWeChat"
    ),
    "Team-prefixed WeChat notification identifier"
  )
  check(
    NotificationDatabaseReader.isWeChatNotificationIdentifier(
      "  5a4re8sf68.COM.TENCENT.XINWECHAT  \n"
    ),
    "Notification identifier should tolerate case and surrounding whitespace"
  )
  check(
    !NotificationDatabaseReader.isWeChatNotificationIdentifier(
      "OTHERTEAM.com.tencent.xinWeChat"
    ),
    "Unknown team-prefixed identifier must be rejected"
  )
  check(
    !NotificationDatabaseReader.isWeChatNotificationIdentifier("com.example.WeChat"),
    "Unrelated notification identifier must be rejected"
  )

  let deliveredAt = Date(timeIntervalSince1970: 1_800_000_000)
  let propertyList: [String: Any] = [
    "req": [
      "titl": "项目群",
      "subt": "张三",
      "body": "明天十点开会",
      "iden": "notification-1",
      "atta": [
        [
          "identifier": "image-1",
          "url": "file:///tmp/wxfomo-notification-image.png",
          "type": "public.png",
        ]
      ],
    ]
  ]
  guard
    let data = try? PropertyListSerialization.data(
      fromPropertyList: propertyList,
      format: .binary,
      options: 0
    )
  else {
    failures.append("Could not create notification plist fixture")
    return
  }

  let decoder = NotificationPayloadDecoder()
  let record = decoder.decode(
    data: data,
    rowID: 42,
    deliveredAt: deliveredAt,
    uuid: "uuid-1"
  )
  check(record?.title == "项目群", "Notification title decoding")
  check(record?.subtitle == "张三", "Notification subtitle decoding")
  check(record?.body == "明天十点开会", "Notification body decoding")
  check(record?.attachments.count == 1, "Notification attachment decoding")
  check(record?.attachments.first?.kind == .image, "Notification image attachment kind")
  check(
    record?.attachments.first?.fileURL.path == "/tmp/wxfomo-notification-image.png",
    "Notification attachment file URL"
  )

  let mapper = NotificationMapper()
  if let record,
    let event = mapper.event(from: record, groups: ["项目群", "其他群"])
  {
    check(event.group == "项目群", "Notification group mapping")
    check(event.senderDisplayName == "张三", "Notification sender mapping")
    check(event.content == "明天十点开会", "Notification content mapping")
    check(event.sourceSequence == 42, "Notification source sequence")
    check(event.attachments.count == 1, "Notification event attachments")
    check(event.messageType == .media, "Attachment should classify the event as media")
    check(event.senderConfidence == .notificationPayload, "Notification confidence")
  } else {
    failures.append("Notification record should map to an event")
  }

  let prefixedRecord = NotificationRecord(
    rowID: 43,
    uuid: nil,
    deliveredAt: deliveredAt,
    title: "项目群",
    subtitle: "",
    body: "李四：接口已上线",
    identifier: "notification-2"
  )
  let prefixedEvent = mapper.event(from: prefixedRecord, groups: ["项目群"])
  check(prefixedEvent?.senderDisplayName == "李四", "Sender prefix mapping")
  check(prefixedEvent?.content == "接口已上线", "Sender prefix content")

  let mentionRecord = NotificationRecord(
    rowID: 44,
    uuid: nil,
    deliveredAt: deliveredAt,
    title: "项目群",
    subtitle: "",
    body: "秋日的晚霞在群聊中@了你",
    identifier: "notification-3"
  )
  let mentionEvent = mapper.event(from: mentionRecord, groups: ["项目群"])
  check(mentionEvent?.senderDisplayName == "秋日的晚霞", "Mention notice sender mapping")
  check(
    mentionEvent?.content == "秋日的晚霞在群聊中@了你",
    "Mention notice content remains intact"
  )

  let overlappingGroupsRecord = NotificationRecord(
    rowID: 45,
    uuid: nil,
    deliveredAt: deliveredAt,
    title: "Alpha 1337",
    subtitle: "成员",
    body: "CA: 0x1111111111111111111111111111111111111111",
    identifier: "notification-overlap"
  )
  check(
    mapper.event(from: overlappingGroupsRecord, groups: ["Alpha", "Alpha 1337"])?.group == "Alpha 1337",
    "Overlapping group names must prefer the longest complete match"
  )

  check(
    mapper.event(from: prefixedRecord, groups: ["不相关群"]) == nil,
    "Notification group allowlist"
  )

  let zeroWidthSpace = String(UnicodeScalar(0x200B)!)
  let invisibleSpacingRecord = NotificationRecord(
    rowID: 45,
    uuid: nil,
    deliveredAt: deliveredAt,
    title: "Alpha" + zeroWidthSpace + " 1337",
    subtitle: "张三",
    body: "零宽空格测试",
    identifier: "notification-4"
  )
  check(
    mapper.event(from: invisibleSpacingRecord, groups: ["Alpha 1337"])?.group == "Alpha 1337",
    "Group mapping should tolerate invisible and regular spaces"
  )
}

private func testMessageEventOrdering() {
  let time = Date(timeIntervalSince1970: 1_800_000_000)
  let laterSequence = MessageEvent(
    eventID: "later-sequence",
    group: "测试群",
    senderDisplayName: "张三",
    content: "第二条",
    messageType: .text,
    observedAt: time,
    sourceSequence: 12,
    senderConfidence: .notificationPayload,
    isFromSelf: false
  )
  let earlierSequence = MessageEvent(
    eventID: "earlier-sequence",
    group: "测试群",
    senderDisplayName: "李四",
    content: "第一条",
    messageType: .text,
    observedAt: time,
    sourceSequence: 11,
    senderConfidence: .notificationPayload,
    isFromSelf: false
  )
  let earlierTime = MessageEvent(
    eventID: "earlier-time",
    group: "测试群",
    senderDisplayName: "王五",
    content: "更早",
    messageType: .text,
    observedAt: time.addingTimeInterval(-1),
    sourceSequence: 99,
    senderConfidence: .notificationPayload,
    isFromSelf: false
  )

  let sorted = [laterSequence, earlierSequence, earlierTime].sorted(by: MessageEventOrder.precedes)
  check(
    sorted.map(\.eventID) == ["earlier-time", "earlier-sequence", "later-sequence"],
    "Message events should sort by delivery time and source sequence"
  )

  let latestFirst = sorted.sorted(by: MessageEventOrder.latestFirst)
  check(
    latestFirst.map(\.eventID) == ["later-sequence", "earlier-sequence", "earlier-time"],
    "Message events should support a stable latest-first presentation order"
  )
}

private func testOCRGeometryExtraction() {
  let lines = [
    OCRLine(
      text: "张三",
      frame: ElementFrame(x: 0.10, y: 0.15, width: 0.08, height: 0.014),
      confidence: 1
    ),
    OCRLine(
      text: "明天十点开会",
      frame: ElementFrame(x: 0.13, y: 0.18, width: 0.25, height: 0.022),
      confidence: 1
    ),
    OCRLine(
      text: "收到",
      frame: ElementFrame(x: 0.78, y: 0.25, width: 0.10, height: 0.022),
      confidence: 1
    ),
  ]
  let rows = OCRMessageExtractor().extract(
    lines: lines,
    group: "项目群",
    contentMinX: 0
  )
  check(rows.count == 2, "OCR row extraction count")
  if rows.count == 2 {
    check(rows[0].labels == ["张三", "明天十点开会"], "OCR incoming sender pairing")
    check(rows[1].labels == ["我说：收到"], "OCR outgoing classification")
  }
}

private func testNotificationMonitorRecovery() async {
  let reader = FakeNotificationReader()
  let collector = NotificationMonitorCollector()
  let monitor = WeChatNotificationMonitor(
    reader: reader,
    groups: ["测试群"],
    pollInterval: 0.02,
    watchesFileSystem: false,
    onEvent: collector.receive,
    onHealth: collector.receive
  )
  let task = Task { try await monitor.run() }

  try? await Task.sleep(for: .milliseconds(30))
  reader.append(fixtureNotification(rowID: 1, uuid: "timer-only"))
  reader.failNextBatches(1)
  try? await Task.sleep(for: .milliseconds(140))
  task.cancel()
  _ = try? await task.value

  check(collector.events.count == 1, "Timer scan should recover and emit without file events")
  let expectedEventID = NotificationMapper().event(
    from: fixtureNotification(rowID: 1, uuid: "timer-only"),
    groups: ["测试群"]
  )?.eventID
  check(
    collector.events.first?.eventID == expectedEventID,
    "Recovered event identity"
  )
  check(
    collector.health.contains { $0.recoveryCount == 1 && $0.lastError != nil },
    "Transient failure health"
  )
  check(
    collector.health.last?.lastError == nil,
    "Monitor should return to healthy state after transient failure"
  )
}

private func testNotificationMonitorDatabaseReset() async {
  let duplicate = fixtureNotification(rowID: 10, uuid: "same-notification")
  let reader = FakeNotificationReader(records: [duplicate])
  let collector = NotificationMonitorCollector()
  let monitor = WeChatNotificationMonitor(
    reader: reader,
    groups: ["测试群"],
    includeExisting: true,
    pollInterval: 0.02,
    watchesFileSystem: false,
    onEvent: collector.receive,
    onHealth: collector.receive
  )
  let task = Task { try await monitor.run() }

  try? await Task.sleep(for: .milliseconds(30))
  reader.replace(records: [fixtureNotification(rowID: 1, uuid: "same-notification")])
  try? await Task.sleep(for: .milliseconds(60))
  reader.append(fixtureNotification(rowID: 2, uuid: "after-reset", body: "李四：恢复消息"))
  try? await Task.sleep(for: .milliseconds(100))
  task.cancel()
  _ = try? await task.value

  check(collector.events.count == 2, "Database reset should deduplicate old and emit new")
  check(
    collector.health.contains { $0.databaseResetCount == 1 },
    "Database rowid reset health"
  )
}

private func testNotificationMonitorInPlaceUpdateRecovery() async {
  let original = fixtureNotification(rowID: 1, uuid: "updated-in-place", body: "张三：旧消息")
  let reader = FakeNotificationReader(records: [original])
  let collector = NotificationMonitorCollector()
  let monitor = WeChatNotificationMonitor(
    reader: reader,
    groups: ["测试群"],
    pollInterval: 0.02,
    recentSweepInterval: 0.02,
    watchesFileSystem: false,
    onEvent: collector.receive,
    onHealth: collector.receive
  )
  let task = Task { try await monitor.run() }

  try? await Task.sleep(for: .milliseconds(40))
  reader.replace(
    records: [fixtureNotification(rowID: 1, uuid: "updated-in-place", body: "张三：更新消息")]
  )
  try? await Task.sleep(for: .milliseconds(120))
  task.cancel()
  _ = try? await task.value

  check(collector.events.count == 1, "In-place notification update should emit once")
  check(collector.events.first?.content == "更新消息", "In-place update content")
  check(
    collector.health.last?.updatedNotificationRecoveryCount == 1,
    "In-place update recovery health"
  )
}

private func testNotificationMonitorGroupMismatchDiagnosis() async {
  let reader = FakeNotificationReader()
  let collector = NotificationMonitorCollector()
  let monitor = WeChatNotificationMonitor(
    reader: reader,
    groups: ["另一个群"],
    pollInterval: 0.02,
    watchesFileSystem: false,
    onEvent: collector.receive,
    onHealth: collector.receive
  )
  let task = Task { try await monitor.run() }

  try? await Task.sleep(for: .milliseconds(30))
  reader.append(fixtureNotification(rowID: 1, uuid: "unmatched-group"))
  try? await Task.sleep(for: .milliseconds(100))
  task.cancel()
  _ = try? await task.value

  check(collector.events.isEmpty, "Unmatched group must not emit an event")
  check(
    collector.health.last?.latestActivity == .groupNotMonitored,
    "Decoded notification should diagnose a group allowlist mismatch"
  )
  check(
    collector.health.last?.identifiedWeChatNotificationCount == 1,
    "Mismatch health should count identified WeChat notifications"
  )
  check(
    collector.health.last?.decodedNotificationCount == 1,
    "Mismatch health should count decoded notifications"
  )
  check(
    collector.health.last?.unmatchedGroupNotificationCount == 1,
    "Mismatch health should count unmatched group notifications"
  )
}

@MainActor
private func testMessageStorePersistence() async {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("wxfomo-store-selftest-\(UUID().uuidString)", isDirectory: true)
  let databaseURL = directory.appendingPathComponent("messages.sqlite3")
  defer { try? FileManager.default.removeItem(at: directory) }

  let baseDate = Date(timeIntervalSince1970: 1_900_000_000)
  let first = fixtureMessageEvent(
    id: "stored-1",
    content: "项目准备启动",
    observedAt: baseDate,
    sequence: 1
  )
  let second = fixtureMessageEvent(
    id: "stored-2",
    sender: "李四",
    content: "融资资料已经更新",
    observedAt: baseDate.addingTimeInterval(1),
    sequence: 2
  )
  let third = fixtureMessageEvent(
    id: "stored-3",
    group: "另一个群",
    sender: nil,
    content: "没有发送者",
    observedAt: baseDate.addingTimeInterval(2),
    sequence: 3
  )

  do {
    let store = try MessageStore(databaseURL: databaseURL)
    let batch = try await store.insert([first, second, third])
    check(batch.insertedCount == 3, "Message store batch insert")
    let duplicateResult = try await store.insert(first)
    check(duplicateResult == .existing, "Message store event ID deduplication")

    let groupPage = try await store.messages(
      matching: MessageQuery(scope: MessageScope(groups: ["测试群"]), limit: 10)
    )
    check(groupPage.messages.map(\.event.eventID) == ["stored-2", "stored-1"], "Message store group query and ordering")

    let searchPage = try await store.messages(
      matching: MessageQuery(scope: MessageScope(searchText: "融资"), limit: 10)
    )
    check(searchPage.messages.map(\.event.eventID) == ["stored-2"], "Message store Chinese search fallback")

    let statistics = try await store.statistics()
    check(statistics.capturedCount == 3, "Message store statistics count")
    check(statistics.conversationCount == 2, "Message store conversation count")
    check(statistics.senderCount == 2, "Message store sender count")
    check(statistics.unknownSenderCount == 1, "Message store unknown sender count")

    let cursor = try await store.setReviewCursor(group: "测试群", eventID: second.eventID)
    check(cursor.eventID == second.eventID, "Message store review cursor")
    let unchangedCursor = try await store.setReviewCursor(group: "测试群", eventID: first.eventID)
    check(
      unchangedCursor.eventID == second.eventID,
      "Message store review cursor must not move backwards"
    )

    let tag = try await store.upsertTag(name: "重点", colorHex: "#D97706")
    let taggedCount = try await store.setTag(tag.id, onEventIDs: [second.eventID])
    check(taggedCount == 1, "Message store tag assignment")
    let tagged = try await store.messages(
      matching: MessageQuery(scope: MessageScope(tagIDs: [tag.id]), limit: 10)
    )
    check(tagged.messages.map(\.event.eventID) == [second.eventID], "Message store tag query")
    let excludedTag = try await store.messages(
      matching: MessageQuery(
        scope: MessageScope(excludedTagIDs: [tag.id]),
        limit: 10
      )
    )
    check(
      !excludedTag.messages.map(\.event.eventID).contains(second.eventID),
      "Message store excluded tag query"
    )
    let anyMatch = try await store.messages(
      matching: MessageQuery(
        scope: MessageScope(
          anyMatch: MessageScopeAnyMatch(tagIDs: [tag.id], terms: ["项目"])
        ),
        limit: 10
      )
    )
    check(
      Set(anyMatch.messages.map(\.event.eventID)) == [first.eventID, second.eventID],
      "Message store tag-or-term query"
    )
    let localFilters = try await store.messages(
      matching: MessageQuery(
        scope: MessageScope(
          includeAnyTerms: ["融资", "不会命中"],
          excludeAnyTerms: ["不会排除"],
          contentContainsAnyTerms: ["资料"],
          requiresKnownSender: true
        ),
        limit: 10
      )
    )
    check(
      localFilters.messages.map(\.event.eventID) == [second.eventID],
      "Message store local presentation filters"
    )

    let frozen = try await store.freeze(scope: MessageScope(groups: ["测试群"]))
    let late = fixtureMessageEvent(
      id: "stored-late",
      content: "冻结后进入",
      observedAt: baseDate.addingTimeInterval(3),
      sequence: 4
    )
    _ = try await store.insert(late)
    let context = try await store.messages(
      aroundEventID: second.eventID,
      beforeLimit: 1,
      afterLimit: 1
    )
    check(
      context.map(\.event.eventID) == [late.eventID, second.eventID, first.eventID],
      "Message context query should center the exact event in newest-first order"
    )
    let frozenMessages = try await store.messages(inFrozenRange: frozen.id)
    check(frozenMessages.map(\.event.eventID) == ["stored-1", "stored-2"], "Frozen range must be immutable")
    let afterReview = try await store.messages(
      matching: MessageQuery(
        scope: MessageScope(
          groups: ["测试群", "另一个群"],
          afterReviewCursors: [unchangedCursor]
        ),
        limit: 10
      )
    )
    check(
      afterReview.messages.map(\.event.eventID) == [late.eventID, third.eventID],
      "Per-group review scope must include each group's unread messages"
    )

    let legacyScopeData = Data(
      #"{"groups":["测试群"],"messageTypes":[],"senders":[],"tagIDs":[]}"#.utf8
    )
    let legacyScope = try JSONDecoder().decode(MessageScope.self, from: legacyScopeData)
    check(legacyScope.groups == ["测试群"], "Legacy message scope decode")
    check(legacyScope.excludedTagIDs.isEmpty, "Legacy message scope default fields")
  } catch {
    failures.append("Message store self-test threw: \(error.localizedDescription)")
    return
  }

  do {
    let reopened = try MessageStore(databaseURL: databaseURL)
    let page = try await reopened.messages(matching: MessageQuery(limit: 10))
    check(page.messages.count == 4, "Message store should survive reopening")
  } catch {
    failures.append("Message store reopen self-test threw: \(error.localizedDescription)")
  }
}

@MainActor
private func testMessageFlowAnalytics() async {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("wxfomo-analytics-selftest-\(UUID().uuidString)", isDirectory: true)
  let databaseURL = directory.appendingPathComponent("messages.sqlite3")
  defer { try? FileManager.default.removeItem(at: directory) }

  let baseDate = Date(timeIntervalSince1970: 1_900_000_000)
  let events = [
    fixtureMessageEvent(
      id: "analytics-1",
      group: "Alpha",
      sender: "Alice",
      senderStableID: "alice-id",
      content: "alpha text one",
      observedAt: baseDate,
      sequence: 1
    ),
    fixtureMessageEvent(
      id: "analytics-2",
      group: "Alpha",
      sender: "Alice",
      senderStableID: "alice-id",
      content: "alpha text two",
      observedAt: baseDate.addingTimeInterval(60),
      sequence: 2
    ),
    fixtureMessageEvent(
      id: "analytics-3",
      group: "Alpha",
      sender: "Bob",
      content: "alpha media",
      messageType: .media,
      observedAt: baseDate.addingTimeInterval(600),
      sequence: 3
    ),
    fixtureMessageEvent(
      id: "analytics-4",
      group: "Beta",
      sender: "Alice New",
      senderStableID: "alice-id",
      content: "beta system signal",
      messageType: .system,
      observedAt: baseDate.addingTimeInterval(1_200),
      sequence: 4
    ),
    fixtureMessageEvent(
      id: "analytics-5",
      group: "Beta",
      sender: nil,
      content: "beta unknown",
      messageType: .unknown,
      observedAt: baseDate.addingTimeInterval(1_210),
      sequence: 5
    ),
  ]

  do {
    let store = try MessageStore(databaseURL: databaseURL)
    _ = try await store.insert(events)

    let analytics = try await store.flowAnalytics(topLimit: 10)
    check(analytics.statistics.capturedCount == 5, "Flow analytics captured total")
    check(analytics.bucketGranularity == .fiveMinutes, "Flow analytics adaptive bucket")
    check(
      analytics.timeBuckets.map(\.capturedCount).reduce(0, +) == 5,
      "Flow analytics bucket counts must sum to captured total"
    )
    check(
      zip(analytics.timeBuckets, analytics.timeBuckets.dropFirst()).allSatisfy { pair in
        pair.0.startDate < pair.1.startDate
      },
      "Flow analytics buckets must be ordered"
    )
    check(analytics.peakBucketCount == 2, "Flow analytics peak bucket count")
    check(
      analytics.timeBuckets.allSatisfy {
        $0.endDate.timeIntervalSince($0.startDate) == analytics.bucketGranularity.duration
      },
      "Flow analytics bucket duration must match granularity"
    )

    let groupCounts = Dictionary(
      uniqueKeysWithValues: analytics.groupDistribution.map { ($0.group, $0.capturedCount) }
    )
    check(groupCounts == ["Alpha": 3, "Beta": 2], "Flow analytics group distribution")

    let senderCounts = Dictionary(
      uniqueKeysWithValues: analytics.senderDistribution.map {
        ($0.identityKey, $0.capturedCount)
      }
    )
    check(senderCounts["id:alice-id"] == 3, "Flow analytics stable sender count")
    check(
      analytics.senderDistribution.first { $0.identityKey == "id:alice-id" }?.displayName
        == "Alice New",
      "Flow analytics should use the latest available sender display name"
    )
    check(senderCounts["name:Bob"] == 1, "Flow analytics named sender count")
    check(senderCounts["unknown"] == 1, "Flow analytics unknown sender count")

    let typeCounts = Dictionary(
      uniqueKeysWithValues: analytics.messageTypeDistribution.map {
        ($0.messageType, $0.capturedCount)
      }
    )
    check(typeCounts[.text] == 2, "Flow analytics text type count")
    check(typeCounts[.media] == 1, "Flow analytics media type count")
    check(typeCounts[.system] == 1, "Flow analytics system type count")
    check(typeCounts[.unknown] == 1, "Flow analytics unknown type count")

    let top = try await store.flowAnalytics(topLimit: 1)
    check(top.groupDistribution == [
      FlowAnalyticsGroupDistribution(group: "Alpha", capturedCount: 3)
    ], "Flow analytics top group")
    check(top.senderDistribution.first?.identityKey == "id:alice-id", "Flow analytics top sender")
    check(top.senderDistribution.first?.capturedCount == 3, "Flow analytics top sender count")
    check(top.messageTypeDistribution.count == 4, "Message types must not be truncated by top limit")

    let filteredScope = MessageScope(
      groups: ["Beta"],
      startDate: baseDate.addingTimeInterval(1_100),
      endDate: baseDate.addingTimeInterval(1_205),
      messageTypes: [.system],
      searchText: "signal",
      senders: ["alice-id"]
    )
    let filtered = try await store.flowAnalytics(in: filteredScope, topLimit: 10)
    check(filtered.statistics.capturedCount == 1, "Flow analytics filtered total")
    check(filtered.groupDistribution.first?.group == "Beta", "Flow analytics group filter")
    check(filtered.senderDistribution.first?.identityKey == "id:alice-id", "Flow analytics sender filter")
    check(filtered.messageTypeDistribution == [
      FlowAnalyticsMessageTypeDistribution(messageType: .system, capturedCount: 1)
    ], "Flow analytics message type and search filters")
    check(filtered.timeBuckets.map(\.capturedCount) == [1], "Flow analytics filtered bucket")

    let emptyScope = MessageScope(
      startDate: baseDate.addingTimeInterval(5_000),
      endDate: baseDate.addingTimeInterval(6_000)
    )
    let empty = try await store.flowAnalytics(in: emptyScope)
    check(empty.statistics.capturedCount == 0, "Empty flow analytics total")
    check(empty.timeBuckets.isEmpty, "Empty flow analytics buckets")
    check(empty.groupDistribution.isEmpty, "Empty flow analytics groups")
    check(empty.senderDistribution.isEmpty, "Empty flow analytics senders")
    check(empty.messageTypeDistribution.isEmpty, "Empty flow analytics message types")
    check(empty.peakBucketCount == 0, "Empty flow analytics peak")
  } catch {
    failures.append("Message flow analytics self-test threw: \(error.localizedDescription)")
  }
}

@MainActor
private func testMessageManagementMetrics() async {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("wxfomo-management-selftest-\(UUID().uuidString)", isDirectory: true)
  let databaseURL = directory.appendingPathComponent("messages.sqlite3")
  defer { try? FileManager.default.removeItem(at: directory) }

  let baseDate = Date(timeIntervalSince1970: 1_910_000_000)
  let alphaFirst = fixtureMessageEvent(
    id: "management-alpha-1",
    group: "Alpha",
    sender: "Alice",
    content: "scope baseline",
    observedAt: baseDate,
    sequence: 1
  )
  let alphaPriority = fixtureMessageEvent(
    id: "management-alpha-2",
    group: "Alpha",
    sender: "Alice",
    content: "scope urgent launch",
    observedAt: baseDate.addingTimeInterval(1),
    sequence: 2
  )
  let alphaSuppressedPriority = fixtureMessageEvent(
    id: "management-alpha-3",
    group: "Alpha",
    sender: "Bob",
    content: "scope urgent noise",
    observedAt: baseDate.addingTimeInterval(2),
    sequence: 3
  )
  let alphaLatest = fixtureMessageEvent(
    id: "management-alpha-4",
    group: "Alpha",
    sender: "Alice",
    content: "scope routine",
    observedAt: baseDate.addingTimeInterval(3),
    sequence: 4
  )
  let betaPriority = fixtureMessageEvent(
    id: "management-beta-1",
    group: "Beta",
    sender: "Cara",
    content: "scope tagged update",
    observedAt: baseDate.addingTimeInterval(4),
    sequence: 5
  )
  let betaSuppressed = fixtureMessageEvent(
    id: "management-beta-2",
    group: "Beta",
    sender: "Cara",
    content: "scope suppressed update",
    observedAt: baseDate.addingTimeInterval(5),
    sequence: 6
  )
  let outsideScope = fixtureMessageEvent(
    id: "management-outside",
    group: "Gamma",
    sender: "Dana",
    content: "scope outside",
    observedAt: baseDate.addingTimeInterval(6),
    sequence: 7
  )

  do {
    let store = try MessageStore(databaseURL: databaseURL)
    _ = try await store.insert([
      alphaFirst, alphaPriority, alphaSuppressedPriority, alphaLatest,
      betaPriority, betaSuppressed, outsideScope,
    ])
    let priorityTag = try await store.upsertTag(name: "management-priority")
    let suppressedTag = try await store.upsertTag(name: "management-suppressed")
    _ = try await store.setTag(priorityTag.id, onEventIDs: [betaPriority.eventID])
    _ = try await store.setTag(
      suppressedTag.id,
      onEventIDs: [alphaSuppressedPriority.eventID, betaSuppressed.eventID]
    )

    let parameterCursor = ReviewCursor(
      group: "  Alpha  ",
      eventID: "  \(alphaFirst.eventID)  ",
      observedAt: alphaFirst.observedAt,
      sourceSequence: alphaFirst.sourceSequence,
      updatedAt: baseDate.addingTimeInterval(10)
    )
    let ignoredBaseScopeCursor = ReviewCursor(
      group: "Alpha",
      eventID: alphaLatest.eventID,
      observedAt: alphaLatest.observedAt,
      sourceSequence: alphaLatest.sourceSequence,
      updatedAt: baseDate.addingTimeInterval(11)
    )
    let baseScope = MessageScope(
      groups: ["Alpha", "Beta"],
      startDate: baseDate,
      endDate: baseDate.addingTimeInterval(6),
      messageTypes: [.text],
      searchText: "scope",
      includeAnyTerms: ["scope", "not-present"],
      excludeAnyTerms: ["blocked"],
      contentContainsAnyTerms: ["scope"],
      requiresKnownSender: true,
      afterReviewCursors: [ignoredBaseScopeCursor]
    )
    let metrics = try await store.managementMetrics(
      baseScope: baseScope,
      priorityMatch: MessageScopeAnyMatch(
        tagIDs: [priorityTag.id],
        terms: ["urgent"]
      ),
      suppressedTagIDs: [suppressedTag.id],
      reviewCursors: [parameterCursor]
    )

    check(metrics.baseCapturedCount == 6, "Management base captured count")
    check(metrics.unsuppressedCapturedCount == 4, "Management unsuppressed count")
    check(metrics.priorityCapturedCount == 2, "Management priority excludes suppressed")
    check(metrics.suppressedCapturedCount == 2, "Management suppressed count")
    check(metrics.pendingReviewCount == 3, "Management per-group pending review count")
    check(
      metrics.oldestPendingReviewObservedAt == alphaPriority.observedAt,
      "Management oldest pending review timestamp"
    )
    check(metrics.priorityRate == 0.5, "Management priority rate denominator")
    check(
      metrics.suppressionRate == Double(2) / Double(6),
      "Management suppression rate denominator"
    )
    let metricsRoundTrip = try JSONDecoder().decode(
      MessageManagementMetrics.self,
      from: JSONEncoder().encode(metrics)
    )
    check(metricsRoundTrip == metrics, "Management metrics Codable round trip")

    let noManagementRules = try await store.managementMetrics(
      baseScope: baseScope,
      priorityMatch: MessageScopeAnyMatch(),
      suppressedTagIDs: ["", "   "],
      reviewCursors: []
    )
    check(noManagementRules.baseCapturedCount == 6, "Management ignores base scope cursor")
    check(noManagementRules.unsuppressedCapturedCount == 6, "Empty suppression tags")
    check(noManagementRules.suppressedCapturedCount == 0, "Empty suppressed count")
    check(noManagementRules.priorityCapturedCount == 0, "Empty priority match")
    check(noManagementRules.pendingReviewCount == 6, "No wxFomo cursor means all pending")
    check(
      noManagementRules.oldestPendingReviewObservedAt == alphaFirst.observedAt,
      "No-cursor oldest pending timestamp"
    )

    var emptyScope = baseScope
    emptyScope.startDate = baseDate.addingTimeInterval(100)
    emptyScope.endDate = baseDate.addingTimeInterval(200)
    let empty = try await store.managementMetrics(
      baseScope: emptyScope,
      priorityMatch: MessageScopeAnyMatch(terms: ["urgent"]),
      suppressedTagIDs: [suppressedTag.id]
    )
    check(empty.baseCapturedCount == 0, "Empty management base count")
    check(empty.unsuppressedCapturedCount == 0, "Empty management unsuppressed count")
    check(empty.priorityCapturedCount == 0, "Empty management priority count")
    check(empty.suppressedCapturedCount == 0, "Empty management suppressed count")
    check(empty.pendingReviewCount == 0, "Empty management pending count")
    check(empty.oldestPendingReviewObservedAt == nil, "Empty management oldest pending")
    check(empty.priorityRate == nil, "Empty management priority rate")
    check(empty.suppressionRate == nil, "Empty management suppression rate")
  } catch {
    failures.append("Message management metrics self-test threw: \(error.localizedDescription)")
  }
}

private func testRulesAndQuantification() {
  let event = fixtureMessageEvent(
    id: "rule-event",
    group: "项目群",
    sender: "负责人",
    content: "紧急：请在明天完成发布",
    observedAt: Date(timeIntervalSince1970: 1_900_000_000),
    sequence: 10
  )
  let matchingRule = MessageRule(
    id: "urgent-project",
    name: "紧急项目消息",
    priority: 100,
    condition: MessageRuleCondition(
      groups: ["项目群"],
      includeKeywords: ["紧急", "明天"],
      includeKeywordMode: .all
    ),
    actions: [.capture, .addTag("紧急"), .localAlert(severity: .warning, title: "项目提醒")]
  )
  let invalidRule = MessageRule(
    id: "invalid-regex",
    name: "无效正则",
    priority: 10,
    condition: MessageRuleCondition(regularExpressions: ["["]),
    actions: [.capture]
  )
  let evaluation = MessageRuleEngine.evaluate(event, rules: [invalidRule, matchingRule])
  check(evaluation.matchedRuleIDs == [matchingRule.id], "Rules should evaluate deterministically")
  check(evaluation.shouldCapture, "Matching rule capture intent")
  check(evaluation.tags == ["紧急"], "Matching rule tag intent")
  check(
    evaluation.traces.first { $0.ruleID == invalidRule.id }?.status == .invalid,
    "Invalid regex must not crash or match"
  )

  let recommendedRules = RecommendedMessageRuleCatalog.rules
  check(recommendedRules.count == 5, "Recommended crypto rule count")
  check(Set(recommendedRules.map(\.id)).count == recommendedRules.count, "Recommended rule IDs")
  check(
    recommendedRules.allSatisfy { MessageRuleEngine.validationReasons(for: $0).isEmpty },
    "Recommended rules must validate"
  )

  let bareAddressEvent = fixtureMessageEvent(
    id: "recommended-bare-ca",
    content: "0x36fd56b4e8e47d2c1cc14072a98898b25d5e7777",
    observedAt: event.observedAt,
    sequence: 11
  )
  let bareAddressEvaluation = MessageRuleEngine.evaluate(
    bareAddressEvent,
    rules: recommendedRules
  )
  check(
    bareAddressEvaluation.matchedRuleIDs.contains("recommended.capture.bare-ca"),
    "Recommended bare CA capture"
  )
  check(bareAddressEvaluation.shouldCapture, "Recommended bare CA should be captured")

  let riskEvent = fixtureMessageEvent(
    id: "recommended-risk",
    content: "警告：疑似貔貅，冻结权限没有放弃",
    observedAt: event.observedAt,
    sequence: 12
  )
  let riskEvaluation = MessageRuleEngine.evaluate(riskEvent, rules: recommendedRules)
  check(
    riskEvaluation.matchedRuleIDs.contains("recommended.risk.contract-liquidity"),
    "Recommended contract risk match"
  )
  check(riskEvaluation.tags.contains("高风险"), "Recommended risk tag")
  check(
    riskEvaluation.actionIntents.contains { intent in
      if case let .localAlert(severity, _) = intent.action {
        return severity == .critical
      }
      return false
    },
    "Recommended risk must raise a critical alert"
  )

  let chatterEvent = fixtureMessageEvent(
    id: "recommended-chatter",
    content: "今天吃什么",
    observedAt: event.observedAt,
    sequence: 13
  )
  check(
    MessageRuleEngine.evaluate(chatterEvent, rules: recommendedRules).matchedRuleIDs.isEmpty,
    "Recommended rules should ignore ordinary chatter"
  )

  let scoring = MessageQuantificationConfiguration(
    weights: MessageDimensionValues(
      relevance: 0.3,
      urgency: 0.25,
      actionability: 0.2,
      novelty: 0.1,
      sourceWeight: 0.15
    ),
    features: [
      MessageScoreFeature(
        id: "urgent-keyword",
        name: "紧急关键词",
        dimension: .urgency,
        points: 80,
        condition: MessageRuleCondition(includeKeywords: ["紧急"])
      )
    ]
  )
  let score = MessageQuantifier.score(event, configuration: scoring)
  check(score.source == .ruleBased, "Quantification source must be explicit")
  check(score.totalScore != nil, "Quantification should produce weighted score")
  check(
    score.limitations.contains(.collectionCompletenessNotMeasured),
    "Quantification must not claim collection completeness"
  )

  let flow = CapturedMessageFlowCounter.summarize([event, event])
  check(flow.inputEventCount == 2, "Captured flow input count")
  check(flow.uniqueEventCount == 1, "Captured flow dedup count")
  check(flow.duplicateEventIDCount == 1, "Captured flow duplicate count")
}

private func testAIProviderConfigurationSafety() {
  do {
    _ = try AIProviderConfiguration(
      displayName: "OpenAI",
      kind: .openAIResponses,
      model: "gpt-test",
      credentialReference: "selftest"
    )
  } catch {
    failures.append("Official AI provider configuration should validate")
  }

  do {
    let configuration = try AIProviderConfiguration(
      displayName: "本机兼容服务",
      kind: .openAICompatibleChatCompletions,
      baseURL: URL(string: "http://127.0.0.1:11434/v1"),
      model: "local-model",
      credentialReference: "selftest-local"
    )
    let endpointURL = try configuration.endpointURL()
    check(
      endpointURL.absoluteString == "http://127.0.0.1:11434/v1/chat/completions",
      "OpenAI-compatible /v1 base URL should append chat/completions once"
    )
  } catch {
    failures.append("Loopback HTTP AI provider should validate")
  }

  do {
    let root = try AIProviderConfiguration(
      displayName: "Supertoken root",
      kind: .openAICompatibleChatCompletions,
      baseURL: URL(string: "https://api.supertoken.cc"),
      model: "gpt-5.6-sol",
      credentialReference: "selftest-supertoken-root"
    )
    let rootEndpointURL = try root.endpointURL()
    let rootCatalogURL = try root.modelCatalogURL()
    check(
      rootEndpointURL.absoluteString == "https://api.supertoken.cc/v1/chat/completions",
      "Compatible root URL should receive the conventional /v1 endpoint"
    )
    check(
      rootCatalogURL.absoluteString == "https://api.supertoken.cc/v1/models",
      "Compatible root URL should produce the /v1/models catalog endpoint"
    )

    let complete = try AIProviderConfiguration(
      displayName: "Supertoken complete",
      kind: .openAICompatibleChatCompletions,
      baseURL: URL(string: "https://api.supertoken.cc/v1/chat/completions/"),
      model: "gpt-5.6-sol",
      credentialReference: "selftest-supertoken-complete"
    )
    let completeEndpointURL = try complete.endpointURL()
    let completeCatalogURL = try complete.modelCatalogURL()
    check(
      completeEndpointURL.absoluteString == "https://api.supertoken.cc/v1/chat/completions",
      "A complete chat/completions URL must not duplicate the endpoint path"
    )
    check(
      completeCatalogURL.absoluteString == "https://api.supertoken.cc/v1/models",
      "A complete chat endpoint should resolve its sibling model catalog"
    )

    let customPath = try AIProviderConfiguration(
      displayName: "Custom compatible path",
      kind: .openAICompatibleChatCompletions,
      baseURL: URL(string: "https://gateway.example.com/openai/v2"),
      model: "custom-model",
      credentialReference: "selftest-custom-path"
    )
    let customEndpointURL = try customPath.endpointURL()
    check(
      customEndpointURL.absoluteString
        == "https://gateway.example.com/openai/v2/chat/completions",
      "A compatible custom base path should be preserved"
    )
  } catch {
    failures.append("Compatible endpoint normalization threw: \(error.localizedDescription)")
  }

  do {
    _ = try AIProviderConfiguration(
      displayName: "不安全服务",
      kind: .openAICompatibleChatCompletions,
      baseURL: URL(string: "http://example.com/v1"),
      model: "model",
      credentialReference: "selftest-insecure"
    )
    failures.append("Non-loopback HTTP AI provider must be rejected")
  } catch {
    check(true, "Non-loopback HTTP rejected")
  }
}

private func testFileConfigurationCenterStore() {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("wxfomo-configuration-center-selftest-\(UUID().uuidString)")
  let fileURL = directory.appendingPathComponent("configuration-center.json")
  defer { try? FileManager.default.removeItem(at: directory) }

  do {
    let primary = try AIProviderConfiguration(
      configurationID: "configuration-center-primary",
      displayName: "Primary",
      kind: .openAICompatibleChatCompletions,
      baseURL: URL(string: "https://api.supertoken.cc/v1"),
      model: "gpt-5.6-sol",
      credentialReference: "primary-reference"
    )
    let secondary = try AIProviderConfiguration(
      configurationID: "configuration-center-secondary",
      displayName: "Secondary",
      kind: .anthropicMessages,
      model: "claude-selftest",
      credentialReference: "secondary-reference"
    )
    let store = FileConfigurationCenterStore(fileURL: fileURL)
    try store.storeAPIKey("primary-selftest-key", for: primary)
    try store.storeAPIKey("secondary-selftest-key", for: secondary)

    var speech = NotificationSpeechConfiguration()
    speech.voiceID = NotificationSpeechConfiguration.sophieVoiceID
    speech.seedStreamModel = "seed-tts-2.0-expressive-selftest"
    speech.maximumCharacters = 888
    speech.cacheTTLSeconds = 123
    try store.storeSpeechConfiguration(speech, updatingAPIKey: "speech-selftest-key")

    let reloaded = FileConfigurationCenterStore(fileURL: fileURL)
    let reloadedPrimaryKey = try reloaded.apiKey(for: primary)
    let reloadedSecondaryKey = try reloaded.apiKey(for: secondary)
    let reloadedSpeechKey = try reloaded.speechAPIKey()
    check(
      reloadedPrimaryKey == "primary-selftest-key",
      "Configuration center should retain the first provider key"
    )
    check(
      reloadedSecondaryKey == "secondary-selftest-key",
      "Configuration center should retain independently scoped provider keys"
    )
    check(
      reloadedSpeechKey == "speech-selftest-key",
      "Configuration center should retain the speech key"
    )
    let reloadedSpeech = try reloaded.speechConfiguration()
    check(
      reloadedSpeech.voiceID == NotificationSpeechConfiguration.sophieVoiceID
        && reloadedSpeech.seedStreamModel == "seed-tts-2.0-expressive-selftest"
        && reloadedSpeech.maximumCharacters == 888
        && reloadedSpeech.cacheTTLSeconds == 123,
      "Configuration center should retain speech service parameters"
    )

    let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    check(
      (fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
      "Configuration center file permissions should be 0600"
    )
    check(
      (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
      "Configuration center directory permissions should be 0700"
    )

    try reloaded.deleteAPIKey(for: primary)
    var deletedProviderMissing = false
    do {
      _ = try reloaded.apiKey(for: primary)
    } catch AICredentialStoreError.credentialNotFound {
      deletedProviderMissing = true
    }
    check(deletedProviderMissing, "Deleting one provider key should remove only that key")
    let preservedSecondaryKey = try reloaded.apiKey(for: secondary)
    check(
      preservedSecondaryKey == "secondary-selftest-key",
      "Deleting one provider key should preserve other provider keys"
    )

    try reloaded.deleteSpeechAPIKey()
    var deletedSpeechMissing = false
    do {
      _ = try reloaded.speechAPIKey()
    } catch AICredentialStoreError.credentialNotFound {
      deletedSpeechMissing = true
    }
    check(deletedSpeechMissing, "Deleting the speech key should preserve the configuration file")

    try Data("{not-json".utf8).write(to: fileURL, options: .atomic)
    var invalidDocumentRejected = false
    do {
      _ = try reloaded.speechConfiguration()
    } catch AICredentialStoreError.invalidConfigurationDocument {
      invalidDocumentRejected = true
    }
    check(invalidDocumentRejected, "Invalid configuration center JSON should be rejected")
  } catch {
    failures.append("Configuration center self-test threw: \(error.localizedDescription)")
  }
}

private func testVolcengineSeedStreamParser() {
  let first = Data("first-mp3-frames".utf8)
  let second = Data("second-mp3-frames".utf8)
  let response = [
    #"{"code":0,"message":"","data":"\#(first.base64EncodedString())"}"#,
    #"{"code":0,"message":"","data":"\#(second.base64EncodedString())"}"#,
    #"{"code":20000000,"message":"OK","data":null}"#,
  ].joined(separator: "\n") + "\n"
  let bytes = Data(response.utf8)
  let splitOffsets = [1, 17, 73, 109, bytes.count]

  do {
    var parser = VolcengineSeedStreamParser()
    var offset = 0
    var streamedChunks: [Data] = []
    for end in splitOffsets {
      streamedChunks += try parser.consume(Data(bytes[offset..<end]))
      offset = end
    }
    let audio = try parser.finish()
    check(parser.isComplete, "Seed stream parser completion frame")
    check(parser.audioChunkCount == 2, "Seed stream parser audio chunk count")
    check(
      streamedChunks.reduce(into: Data()) { $0.append($1) } == first + second,
      "Seed stream parser should emit audio despite arbitrary network splits"
    )
    check(audio == first + second, "Seed stream parser should concatenate MP3 fragments")
  } catch {
    failures.append("Seed stream parser self-test threw: \(error.localizedDescription)")
  }

  do {
    var parser = VolcengineSeedStreamParser()
    _ = try parser.consume(
      Data(#"{"code":55000000,"message":"resource mismatch","data":null}"#.utf8)
    )
    _ = try parser.finish()
    failures.append("Seed stream provider error should be rejected")
  } catch VolcengineSeedStreamError.provider(let code, _) {
    check(code == 55_000_000, "Seed stream parser should preserve provider error code")
  } catch {
    failures.append("Seed stream provider error had wrong type: \(error.localizedDescription)")
  }

  do {
    var parser = VolcengineSeedStreamParser()
    _ = try parser.consume(
      Data(#"{"code":0,"data":"YXVkaW8="}"#.utf8)
    )
    _ = try parser.finish()
    failures.append("Seed stream without completion should be rejected")
  } catch VolcengineSeedStreamError.incomplete {
    check(true, "Seed stream requires completion frame")
  } catch {
    failures.append("Incomplete Seed stream had wrong error: \(error.localizedDescription)")
  }
}

@MainActor
private func testAIProviderConnectionTester() async {
  let configuration: AIProviderConfiguration
  do {
    configuration = try AIProviderConfiguration(
      configurationID: "connection-test-provider",
      displayName: "Connection test",
      kind: .openAICompatibleChatCompletions,
      baseURL: URL(string: "https://api.supertoken.cc/v1"),
      model: "gpt-5.6-sol",
      credentialReference: "connection-test-key"
    )
  } catch {
    failures.append("Connection tester fixture creation threw: \(error.localizedDescription)")
    return
  }
  let credentialStore = SelfTestAICredentialStore()
  do {
    try credentialStore.storeAPIKey("selftest-secret", for: configuration)
  } catch {
    failures.append("Connection tester credential fixture threw: \(error.localizedDescription)")
    return
  }

  let catalogData = Data(#"{"data":[{"id":"gpt-5.6-sol"},{"id":"other-model"}]}"#.utf8)
  let transport = SelfTestAIHTTPTransport(
    response: AIHTTPResponse(statusCode: 200, headers: [:], data: catalogData)
  )
  let tester = AIProviderConnectionTester(
    credentialStore: credentialStore,
    transport: transport
  )
  let result = await tester.test(
    configuration,
    now: Date(timeIntervalSince1970: 1_930_000_000)
  )
  check(result.status == .success, "A matching model catalog should verify the provider")
  check(result.code == .catalogVerified, "Connection tester verified result code")
  check(result.availableModelCount == 2, "Connection tester should report catalog size")
  check(transport.lastRequest?.httpMethod == "GET", "Connection test must only issue a GET")
  check(
    transport.lastRequest?.url?.absoluteString == "https://api.supertoken.cc/v1/models",
    "Connection test must target the model catalog, not a generation endpoint"
  )
  check(
    transport.lastRequest?.httpBody == nil,
    "Connection test must not include a generation request body"
  )
  check(
    transport.lastRequest?.value(forHTTPHeaderField: "Authorization")
      == "Bearer selftest-secret",
    "Connection test should use the configured bearer credential"
  )

  let unsupportedTransport = SelfTestAIHTTPTransport(
    response: AIHTTPResponse(statusCode: 404, headers: [:], data: Data())
  )
  let unsupported = await AIProviderConnectionTester(
    credentialStore: credentialStore,
    transport: unsupportedTransport
  ).test(configuration)
  check(
    unsupported.status == .warning && unsupported.code == .catalogUnavailable,
    "A missing model catalog should be a warning, not proof that generation is broken"
  )

  let deniedTransport = SelfTestAIHTTPTransport(
    response: AIHTTPResponse(statusCode: 401, headers: [:], data: Data())
  )
  let denied = await AIProviderConnectionTester(
    credentialStore: credentialStore,
    transport: deniedTransport
  ).test(configuration)
  check(
    denied.status == .failure && denied.code == .authenticationFailed,
    "Authentication failures should be explicit"
  )
}

@MainActor
private func testRemoteAIAnalysisProviderStreaming() async {
  do {
    let configuration = try AIProviderConfiguration(
      configurationID: "streaming-provider",
      displayName: "Streaming provider",
      kind: .openAICompatibleChatCompletions,
      baseURL: URL(string: "https://api.supertoken.cc/v1"),
      model: "gpt-5.6-sol",
      credentialReference: "streaming-provider-key"
    )
    let credentialStore = SelfTestAICredentialStore()
    try credentialStore.storeAPIKey("streaming-selftest-key", for: configuration)

    func event(_ content: String, finishReason: String? = nil) throws -> String {
      let choice: [String: Any] = [
        "index": 0,
        "delta": ["content": content],
        "finish_reason": finishReason ?? NSNull(),
      ]
      let root: [String: Any] = [
        "id": "chatcmpl-streaming-selftest",
        "choices": [choice],
      ]
      let data = try JSONSerialization.data(withJSONObject: root)
      return "data: \(String(decoding: data, as: UTF8.self))\n\n"
    }

    let firstFragment = "{\"summary\":\"发现 "
    let secondFragment = "CA\",\"summary_source_message_ids\":[\"message-1\"],"
      + "\"topics\":[],\"findings\":[],\"crypto_addresses\":[]}"
    let stream = try event(firstFragment)
      + event(secondFragment, finishReason: "stop")
      + "data: [DONE]\n\n"
    let transport = SelfTestAIHTTPTransport(
      response: AIHTTPResponse(
        statusCode: 200,
        headers: ["content-type": "text/event-stream", "x-request-id": "request-stream"],
        data: Data(stream.utf8)
      )
    )
    let provider = try RemoteAIAnalysisProvider(
      configuration: configuration,
      credentialStore: credentialStore,
      transport: transport
    )
    let observedAt = Date(timeIntervalSince1970: 1_950_000_000)
    let request = AIAnalysisRequest(
      requestID: "streaming-request",
      createdAt: observedAt,
      rangeStart: observedAt.addingTimeInterval(-1),
      rangeEnd: observedAt.addingTimeInterval(1),
      mode: .digest,
      localeIdentifier: "zh-CN",
      messages: [
        AIAnalysisSourceMessage(
          messageID: "message-1",
          group: "测试群",
          senderDisplayName: "Alice",
          observedAt: observedAt,
          content: "发现 CA",
          messageType: .text
        )
      ]
    )
    let result = try await provider.analyze(request)
    check(result.summary == "发现 CA", "Streaming chat chunks should be assembled in order")
    check(
      result.summarySourceMessageIDs == ["message-1"],
      "Streaming chat analysis should preserve citations"
    )
    check(
      result.provenance.remoteRequestID == "request-stream"
        && result.provenance.remoteResponseID == "chatcmpl-streaming-selftest",
      "Streaming chat analysis should preserve remote identifiers"
    )
    guard let sentRequest = transport.lastRequest,
      let bodyData = sentRequest.httpBody,
      let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
    else {
      failures.append("Streaming provider should send a JSON request")
      return
    }
    check(body["stream"] as? Bool == true, "Chat Completions should request SSE streaming")
    check(
      sentRequest.value(forHTTPHeaderField: "Accept") == "text/event-stream",
      "Streaming Chat Completions should request the SSE media type"
    )
  } catch {
    failures.append("Streaming AI provider self-test threw: \(error.localizedDescription)")
  }
}

private func testCryptoAddressDetection() {
  check(GMGNChain.eth.cryptoAddressNetwork == .ethereum, "ETH network mapping")
  check(GMGNChain.base.cryptoAddressNetwork == .base, "Base network mapping")
  check(GMGNChain.bsc.cryptoAddressNetwork == .bsc, "BSC network mapping")
  check(
    GMGNChain.robinhood.cryptoAddressNetwork == .robinhood,
    "Robinhood network mapping"
  )
  check(GMGNChain.sol.cryptoAddressNetwork == .solana, "Solana network mapping")
  let evmAddress = "0x6982508145454ce325ddbe47a25d4ec3d2311933"
  let solanaAddress = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
  let baseDate = Date(timeIntervalSince1970: 1_920_000_000)
  let messages = [
    AIAnalysisSourceMessage(
      messageID: "base-before",
      group: "Base 观察群",
      senderDisplayName: "甲",
      observedAt: baseDate,
      content: "这是 Base 链的新项目",
      messageType: .text
    ),
    AIAnalysisSourceMessage(
      messageID: "base-ca-1",
      group: "Base 观察群",
      senderDisplayName: "乙",
      observedAt: baseDate.addingTimeInterval(30),
      content: "CA: \(evmAddress)",
      messageType: .text
    ),
    AIAnalysisSourceMessage(
      messageID: "other-group",
      group: "无关群",
      senderDisplayName: "丙",
      observedAt: baseDate.addingTimeInterval(40),
      content: "这个地址可能在 Ethereum",
      messageType: .text
    ),
    AIAnalysisSourceMessage(
      messageID: "base-ca-2",
      group: "Base 观察群",
      senderDisplayName: "丁",
      observedAt: baseDate.addingTimeInterval(60),
      content: "再次转发 \(evmAddress.uppercased())",
      messageType: .text
    ),
    AIAnalysisSourceMessage(
      messageID: "too-late",
      group: "Base 观察群",
      senderDisplayName: "戊",
      observedAt: baseDate.addingTimeInterval(6 * 60),
      content: "超过上下文窗口的 Ethereum 讨论",
      messageType: .text
    ),
    AIAnalysisSourceMessage(
      messageID: "solana-ca",
      group: "Solana 观察群",
      senderDisplayName: "己",
      observedAt: baseDate.addingTimeInterval(90),
      content: "Solana mint: \(solanaAddress)",
      messageType: .text
    ),
    AIAnalysisSourceMessage(
      messageID: "random-identifier",
      group: "Base 观察群",
      senderDisplayName: "庚",
      observedAt: baseDate.addingTimeInterval(100),
      content: "thisisjustarandomidentifierwithoutchain",
      messageType: .text
    ),
  ]

  let evidence = CryptoAddressDetector.detect(in: messages)
  let evm = evidence.first { $0.normalizedAddress == evmAddress.lowercased() }
  check(evm?.network == .base, "EVM address should use the single explicit Base context hint")
  check(evm?.roleHint == .contractOrToken, "CA context should produce a contract/token role hint")
  check(evm?.occurrenceCount == 2, "Repeated EVM addresses should aggregate occurrences")
  check(
    evm?.directSourceMessageIDs == ["base-ca-1", "base-ca-2"],
    "Repeated EVM addresses should retain ordered direct sources"
  )
  check(
    evm?.contextSourceMessageIDs.contains("base-before") == true,
    "Same-group neighboring messages should be retained as address context"
  )
  check(
    evm?.contextSourceMessageIDs.contains("other-group") == false,
    "Messages from another group must not enter address context"
  )
  check(
    evm?.contextSourceMessageIDs.contains("too-late") == false,
    "Messages outside the five-minute window must not enter address context"
  )

  let solana = evidence.first { $0.normalizedAddress == solanaAddress }
  check(solana?.network == .solana, "A 32-byte Base58 key with Solana context should be detected")
  check(
    evidence.contains { $0.address == "thisisjustarandomidentifierwithoutchain" } == false,
    "A random 32-44 character identifier must not be treated as a Solana address"
  )

  let unhinted = CryptoAddressDetector.detect(in: [
    AIAnalysisSourceMessage(
      messageID: "unhinted-evm",
      group: "普通群",
      senderDisplayName: nil,
      observedAt: baseDate,
      content: evmAddress,
      messageType: .text
    )
  ])
  check(unhinted.first?.network == .evm, "An unhinted 0x address must remain generic EVM")

  let robinhoodHinted = CryptoAddressDetector.detect(in: [
    AIAnalysisSourceMessage(
      messageID: "robinhood-evm",
      group: "Robinhood 观察群",
      senderDisplayName: nil,
      observedAt: baseDate,
      content: "机器人标注 robinhood 副本，CA: \(evmAddress)",
      messageType: .text
    )
  ])
  check(
    robinhoodHinted.first?.network == .robinhood,
    "An explicit Robinhood bot-format hint should classify an EVM address"
  )

  let standaloneSolana = CryptoAddressDetector.detect(in: [
    AIAnalysisSourceMessage(
      messageID: "standalone-solana",
      group: "普通群",
      senderDisplayName: nil,
      observedAt: baseDate,
      content: solanaAddress,
      messageType: .text
    )
  ])
  check(
    standaloneSolana.first?.network == .solana,
    "A standalone valid 32-byte Base58 public key should be detected as Solana-format"
  )

  let directMatches = CryptoAddressDetector.matches(
    in: "CA \(evmAddress) again \(evmAddress.uppercased()) · SOL mint \(solanaAddress)"
  )
  check(directMatches.count == 2, "Public address matches should deduplicate repeated values")
  check(
    directMatches.first?.family == .evm
      && directMatches.first?.normalizedAddress == evmAddress.lowercased(),
    "Public address matches should classify and normalize EVM values"
  )
  check(
    directMatches.last?.family == .solana
      && directMatches.last?.normalizedAddress == solanaAddress,
    "Public address matches should classify valid Solana-format values"
  )

  let networkContexts: [(String, CryptoAddressNetwork)] = [
    ("ETH CA", .ethereum),
    ("BSC CA", .bsc),
    ("Base CA", .base),
    ("Robinhood chain CA", .robinhood),
  ]
  for (prefix, expectedNetwork) in networkContexts {
    let match = CryptoAddressDetector.matches(in: prefix + " " + evmAddress).first
    check(
      match?.network == expectedNetwork,
      "Local address context should classify " + expectedNetwork.rawValue + " network"
    )
  }
  let genericMatch = CryptoAddressDetector.matches(in: evmAddress).first
  check(
    genericMatch?.network == .evm,
    "An EVM address without a network hint should remain in other EVM"
  )
  let secondEVMAddress = "0x1111111111111111111111111111111111111111"
  let splitNetworkMatches = CryptoAddressDetector.matches(
    in: "ETH: " + evmAddress + " / BSC: " + secondEVMAddress
  )
  check(
    splitNetworkMatches.first?.network == .ethereum
      && splitNetworkMatches.last?.network == .bsc,
    "Separate ETH and BSC labels should classify adjacent addresses independently"
  )

  let invalidEVM = String(repeating: "a", count: 40)
  check(
    CryptoAddressDetector.matches(in: "0x\(invalidEVM)f").isEmpty,
    "EVM matching should reject values longer than 40 hexadecimal digits"
  )
  check(
    CryptoAddressDetector.matches(in: "10x\(invalidEVM)").isEmpty,
    "EVM matching should reject a hexadecimal character immediately before 0x"
  )
  check(
    CryptoAddressDetector.matches(in: "tracking thisisjustarandomidentifierwithoutchain").isEmpty,
    "Public matches should reject an unhinted long identifier as Solana"
  )
}

private func testWebLinkDetection() {
  let links = WebLinkDetector.matches(
    in: "官网 https://example.com/token?id=42，备用 HTTP://status.example.org/path。"
  )
  check(links.count == 2, "Explicit HTTP and HTTPS links should be detected")
  check(
    links.first?.url.host == "example.com",
    "Web link detection should preserve the parsed host"
  )
  check(
    links.contains { $0.rawValue.hasSuffix("，") || $0.rawValue.hasSuffix("。") } == false,
    "Trailing Chinese punctuation must not be included in a detected web link"
  )

  let strictMatches = WebLinkDetector.matches(
    in: "example.com ftp://example.com https://example.com https://example.com"
  )
  check(strictMatches.count == 1, "Web links should reject bare domains and FTP, then deduplicate")
  check(
    strictMatches.first?.url.scheme == "https",
    "Only explicit HTTP/HTTPS schemes should pass web link detection"
  )
}

private func testCryptoAddressDetectionAtRequestLimit() {
  let address = "0x6982508145454ce325ddbe47a25d4ec3d2311933"
  let baseDate = Date(timeIntervalSince1970: 1_930_000_000)
  let messages = (0..<AIAnalysisRequest.maximumMessageCount).map { index in
    AIAnalysisSourceMessage(
      messageID: "large-snapshot-\(index)",
      group: "压力测试群",
      senderDisplayName: "成员 \(index % 20)",
      observedAt: baseDate.addingTimeInterval(TimeInterval(index)),
      content: index == 5_000 ? "Base CA: \(address)" : "普通消息 \(index)",
      messageType: .text
    )
  }

  let evidence = CryptoAddressDetector.detect(in: messages)
  check(evidence.count == 1, "Maximum-size analysis snapshot should finish address detection")
  check(evidence.first?.normalizedAddress == address, "Large snapshot address identity")
  check(evidence.first?.network == .base, "Large snapshot address context")
}

@MainActor
private func testDexScreenerChainResolver() async {
  let address = "0x4200000000000000000000000000000000000006"
  let dominantFixture = #"""
    {
      "pairs": [
        {
          "chainId": "base",
          "baseToken": {
            "address": "0x4200000000000000000000000000000000000006",
            "name": "Wrapped Ether",
            "symbol": "WETH"
          },
          "quoteToken": { "address": "0x1111111111111111111111111111111111111111" },
          "liquidity": { "usd": 120000 },
          "volume": { "h24": 80000, "h1": 4000 },
          "priceUsd": "3.25",
          "priceChange": { "h1": 2.5 },
          "marketCap": 750000,
          "fdv": 1000000,
          "info": {
            "imageUrl": "https://cdn.example.test/weth.png",
            "websites": [{ "url": "https://example.test" }],
            "socials": [{ "type": "twitter", "url": "https://x.com/example_token" }]
          }
        },
        {
          "chainId": "base",
          "baseToken": { "address": "0x2222222222222222222222222222222222222222" },
          "quoteToken": { "address": "0x4200000000000000000000000000000000000006" },
          "liquidity": { "usd": 25000 },
          "volume": { "h24": 50000 }
        },
        {
          "chainId": "ethereum",
          "baseToken": { "address": "0x4200000000000000000000000000000000000006" },
          "quoteToken": { "address": "0x3333333333333333333333333333333333333333" },
          "liquidity": { "usd": 30000 },
          "volume": { "h24": 60000 }
        },
        {
          "chainId": "arbitrum",
          "baseToken": { "address": "0x4200000000000000000000000000000000000006" },
          "quoteToken": { "address": "0x4444444444444444444444444444444444444444" },
          "liquidity": { "usd": 999999999 },
          "volume": { "h24": 999999999 }
        }
      ]
    }
    """#
  let dominantTransport = SelfTestAIHTTPTransport(
    response: AIHTTPResponse(
      statusCode: 200,
      headers: [:],
      data: Data(dominantFixture.utf8)
    )
  )
  do {
    let resolver = DexScreenerChainResolver(transport: dominantTransport)
    let resolution = try await resolver.resolve(address: address.uppercased())
    check(resolution.selectedChain == .base, "DexScreener dominant chain selection")
    check(
      resolution.candidates.map(\.chain) == [.base, .eth],
      "DexScreener supported chain filtering and ranking"
    )
    check(
      resolution.candidates.first?.pairCount == 2,
      "DexScreener exact address matching on base and quote sides"
    )
    check(
      dominantTransport.lastRequest?.url?.absoluteString
        == "https://api.dexscreener.com/latest/dex/tokens/\(address)",
      "DexScreener exact token endpoint"
    )
    let snapshot = try await resolver.tokenSnapshot(chain: .base, address: address)
    check(snapshot.symbol == "WETH", "DexScreener token symbol parsing")
    check(snapshot.name == "Wrapped Ether", "DexScreener token name parsing")
    check(snapshot.priceUSD == 3.25, "DexScreener token price parsing")
    check(snapshot.marketCapUSD == 750_000, "DexScreener market cap preference")
    check(snapshot.liquidityUSD == 120_000, "DexScreener main-pair liquidity parsing")
    check(snapshot.volume1hUSD == 4_000, "DexScreener one-hour volume parsing")
    check(snapshot.priceChange1hPercent == 2.5, "DexScreener price change parsing")
    check(snapshot.logoURL == "https://cdn.example.test/weth.png", "DexScreener logo parsing")
    check(snapshot.twitterUsername == "example_token", "DexScreener social parsing")
    check(dominantTransport.requestCount == 1, "DexScreener pair response should be reused")
  } catch {
    failures.append("DexScreener dominant resolver self-test threw: \(error.localizedDescription)")
  }

  let robinhoodFixture = #"""
    {
      "pairs": [
        {
          "chainId": "robinhood",
          "baseToken": {
            "address": "0x4200000000000000000000000000000000000006",
            "name": "Robinhood Fixture",
            "symbol": "RHF"
          },
          "quoteToken": { "address": "0x1111111111111111111111111111111111111111" },
          "liquidity": { "usd": 550000 },
          "volume": { "h24": 90000 },
          "priceUsd": "0.01",
          "marketCap": 1000000
        }
      ]
    }
    """#
  do {
    let resolver = DexScreenerChainResolver(
      transport: SelfTestAIHTTPTransport(
        response: AIHTTPResponse(
          statusCode: 200,
          headers: [:],
          data: Data(robinhoodFixture.utf8)
        )
      )
    )
    let resolution = try await resolver.resolve(address: address)
    check(resolution.selectedChain == .robinhood, "DexScreener Robinhood chain mapping")
    let snapshot = try await resolver.tokenSnapshot(chain: .robinhood, address: address)
    check(snapshot.chain == .robinhood, "DexScreener Robinhood token snapshot")
  } catch {
    failures.append("DexScreener Robinhood resolver self-test threw: \(error.localizedDescription)")
  }

  let ambiguousFixture = #"""
    {
      "pairs": [
        {
          "chainId": "base",
          "baseToken": { "address": "0x4200000000000000000000000000000000000006" },
          "quoteToken": { "address": "0x1111111111111111111111111111111111111111" },
          "liquidity": { "usd": 50000 },
          "volume": { "h24": 80000 }
        },
        {
          "chainId": "ethereum",
          "baseToken": { "address": "0x4200000000000000000000000000000000000006" },
          "quoteToken": { "address": "0x3333333333333333333333333333333333333333" },
          "liquidity": { "usd": 30000 },
          "volume": { "h24": 60000 }
        }
      ]
    }
    """#
  do {
    let resolver = DexScreenerChainResolver(
      transport: SelfTestAIHTTPTransport(
        response: AIHTTPResponse(
          statusCode: 200,
          headers: [:],
          data: Data(ambiguousFixture.utf8)
        )
      )
    )
    let resolution = try await resolver.resolve(address: address)
    check(resolution.selectedChain == nil, "DexScreener ambiguous chains require confirmation")
    check(resolution.isAmbiguous, "DexScreener ambiguous resolution state")
  } catch {
    failures.append("DexScreener ambiguous resolver self-test threw: \(error.localizedDescription)")
  }

  let concurrentTransport = SelfTestAIHTTPTransport(
    response: AIHTTPResponse(statusCode: 200, headers: [:], data: Data(dominantFixture.utf8)),
    delayNanoseconds: 50_000_000
  )
  do {
    let resolver = DexScreenerChainResolver(transport: concurrentTransport)
    async let first = resolver.resolve(address: address)
    async let second = resolver.resolve(address: address.uppercased())
    let resolutions = try await [first, second]
    check(resolutions.allSatisfy { $0.selectedChain == .base }, "Concurrent chain resolution")
    check(
      concurrentTransport.requestCount == 1,
      "Concurrent DexScreener lookups for one address should share one request"
    )
  } catch {
    failures.append("DexScreener concurrent resolver self-test threw: \(error.localizedDescription)")
  }
}

@MainActor
private func testGMGNCLIClient() async {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("wxfomo-gmgn-selftest-\(UUID().uuidString)", isDirectory: true)
  let executableURL = directory.appendingPathComponent("gmgn-cli")
  let callsURL = directory.appendingPathComponent("calls")
  defer { try? FileManager.default.removeItem(at: directory) }
  let script = #"""
    #!/bin/sh
    printf '%s\n' "$*" >> '\#(callsURL.path)'
    if [ "$1" = "config" ]; then
      sleep 0.05
      exit 0
    fi
    if [ "$2" = "info" ] && [ "$6" = "0x5a8625d314fdd298101d87932a784b756a401e18" ]; then
      if [ "$4" = "robinhood" ]; then
        printf '%s' '{"address":"0x5a8625d314fdd298101d87932a784b756a401e18","symbol":"AGI","name":"AGI Frog","holder_count":3714,"circulating_supply":"1000000000","liquidity":"547583.62","price":{"price":"0.0018621422"}}'
      else
        printf '%s' '{"address":"0x5a8625d314fdd298101d87932a784b756a401e18","symbol":"","name":"","holder_count":0,"circulating_supply":"0","liquidity":"0","price":{"price":"0"}}'
      fi
      exit 0
    fi
    if [ "$2" = "info" ]; then
      printf '%s' '{"address":"'"$6"'","symbol":"TEST","name":"Fixture Token","logo":"https://cdn.example.test/token.png","holder_count":42,"circulating_supply":"1000000","liquidity":"25000","price":{"price":"0.5","price_1h":"0.4","volume_1h":"1200"},"wallet_tags_stat":{"smart_wallets":3,"renowned_wallets":1},"link":{"gmgn":"https://gmgn.ai/sol/token/test","geckoterminal":"https://www.geckoterminal.com/solana/pools/test"}}'
      exit 0
    fi
    if [ "$2" = "security" ]; then
      printf '%s' '{"open_source":1,"renounced_mint":true,"renounced_freeze_account":true,"top_10_holder_rate":"0.12","buy_tax":"0","sell_tax":"0"}'
      exit 0
    fi
    exit 2
    """#

  do {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    try script.write(to: executableURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executableURL.path
    )
    let client = GMGNCLIClient(executableURL: executableURL)
    let address = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
    async let firstReportRequest = client.tokenReport(chain: .sol, address: address)
    async let duplicateReportRequest = client.tokenReport(chain: .sol, address: address)
    let (report, duplicateReport) = try await (firstReportRequest, duplicateReportRequest)
    check(report == duplicateReport, "Concurrent GMGN token reports should share one fresh result")
    let initialCalls = (try? String(contentsOf: callsURL, encoding: .utf8))?
      .split(separator: "\n") ?? []
    check(
      initialCalls.filter { $0.hasPrefix("token info --chain sol") }.count == 1,
      "Concurrent GMGN token reports should launch token info once"
    )
    check(
      initialCalls.filter { $0.hasPrefix("token security --chain sol") }.count == 1,
      "Concurrent GMGN token reports should launch token security once"
    )
    check(report.token.symbol == "TEST", "GMGN token symbol parsing")
    check(report.token.marketCapUSD == 500_000, "GMGN market cap calculation")
    check(report.token.priceChange1hPercent == 25, "GMGN one-hour price change calculation")
    check(report.token.smartWalletCount == 3, "GMGN smart wallet parsing")
    check(
      report.token.logoURL == "https://cdn.example.test/token.png",
      "GMGN token logo parsing"
    )
    check(
      report.token.geckoTerminalURL == "https://www.geckoterminal.com/solana/pools/test",
      "GMGN GeckoTerminal link parsing"
    )
    check(report.security?.openSource == "yes", "GMGN numeric security status parsing")
    check(report.security?.isHoneypot == nil, "GMGN Solana honeypot should be not applicable")
    let cached = try await client.tokenReport(chain: .sol, address: address)
    check(cached.isCached, "GMGN token report cache")

    let coldClient = GMGNCLIClient(executableURL: executableURL)
    async let firstColdSnapshot = coldClient.tokenSnapshot(chain: .sol, address: address)
    async let secondColdSnapshot = coldClient.tokenSnapshot(
      chain: .sol,
      address: "So11111111111111111111111111111111111111112"
    )
    _ = try await (firstColdSnapshot, secondColdSnapshot)
    let configurationCalls = (try? String(contentsOf: callsURL, encoding: .utf8))?
      .split(separator: "\n")
      .filter { $0 == "config --check" }
      .count
    check(
      configurationCalls == 2,
      "Concurrent cold GMGN requests should share one configuration check"
    )

    let robinhoodAddress = "0x4200000000000000000000000000000000000006"
    let robinhood = try await client.tokenReport(
      chain: .robinhood,
      address: robinhoodAddress.uppercased()
    )
    check(robinhood.token.chain == .robinhood, "GMGN Robinhood chain forwarding")
    check(
      robinhood.token.address == robinhoodAddress.lowercased(),
      "GMGN Robinhood address normalization"
    )

    var invalidRobinhoodRejected = false
    do {
      _ = try await client.tokenReport(chain: .robinhood, address: "not-an-address")
    } catch let error as GMGNCLIError {
      if case .invalidAddress(chain: .robinhood) = error {
        invalidRobinhoodRejected = true
      }
    }
    check(invalidRobinhoodRejected, "GMGN Robinhood address validation")

    let identifiedAddress = "0x5a8625d314fdd298101d87932a784b756a401e18"
    let identified = try await client.identifyEVMToken(address: identifiedAddress)
    check(identified.count == 1, "GMGN EVM chain identification filters empty placeholders")
    check(identified.first?.chain == .robinhood, "GMGN identifies a Robinhood token")
    check(identified.first?.symbol == "AGI", "GMGN chain identification keeps token metadata")
    let cachedIdentification = try await client.identifyEVMToken(address: identifiedAddress)
    check(cachedIdentification == identified, "GMGN chain identification cache")

    let rateExecutableURL = directory.appendingPathComponent("gmgn-cli-rate-limited")
    let callsURL = directory.appendingPathComponent("rate-limit-calls")
    let rateScript = """
      #!/bin/sh
      if [ "$1" = "config" ]; then
        exit 0
      fi
      printf '1\\n' >> '\(callsURL.path)'
      printf '%s' '[gmgn-cli] GET /v1/token/info failed: HTTP 429 code=429 error=RATE_LIMIT_BANNED reset_at=1930000300' >&2
      exit 1
      """
    try rateScript.write(to: rateExecutableURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: rateExecutableURL.path
    )
    let limitedClient = GMGNCLIClient(executableURL: rateExecutableURL)
    let limitTestNow = Date(timeIntervalSince1970: 1_930_000_000)
    var parsedRetryAt: Date?
    do {
      _ = try await limitedClient.tokenSnapshot(
        chain: .sol,
        address: address,
        now: limitTestNow
      )
    } catch let error as GMGNCLIError {
      if case .rateLimited(let retryAt) = error { parsedRetryAt = retryAt }
    }
    check(
      parsedRetryAt == Date(timeIntervalSince1970: 1_930_000_300),
      "GMGN rate-limit reset timestamp parsing"
    )
    do {
      _ = try await limitedClient.tokenSnapshot(
        chain: .sol,
        address: address,
        now: limitTestNow.addingTimeInterval(1)
      )
    } catch {}
    let callCount = (try? String(contentsOf: callsURL, encoding: .utf8))?
      .split(whereSeparator: \.isNewline).count
    check(callCount == 1, "GMGN cooldown should block repeated external requests")
  } catch {
    failures.append("GMGN CLI client self-test threw: \(error.localizedDescription)")
  }
}

private func testTradeAutomationRiskEngine() {
  let now = Date(timeIntervalSince1970: 1_940_000_000)
  let rule = TradeAutomationRule(createdAt: now, updatedAt: now).normalized
  check(rule.validationIssues.isEmpty, "Default trade rule validation")
  check(
    rule.protectionOrders.map(\.triggerPercent) == [100, 200, 50],
    "Default protection plan should take profit at +100%, +200% and stop at -50%"
  )
  check(
    rule.protectionOrders.map(\.triggerDescription) == ["上涨 100%", "上涨 200%", "下跌 50%"],
    "Protection plan must expose direction explicitly"
  )
  check(
    GMGNNativeAsset.smallestUnitAmount(0.01, chain: .sol) == "10000000",
    "SOL amount conversion must use lamports"
  )
  check(
    GMGNNativeAsset.smallestUnitAmount(0.01, chain: .eth) == "10000000000000000",
    "EVM amount conversion must use 18 decimals"
  )
  check(
    GMGNNativeAsset.smallestUnitAmount(0.01, chain: .base) == "10000000000000000"
      && GMGNNativeAsset.smallestUnitAmount(0.01, chain: .bsc) == "10000000000000000",
    "Base and BSC amount conversion must use 18 decimals"
  )
  func safetySnapshot(
    rugRatio: Double?,
    isHoneypot: String? = "no"
  ) -> GMGNTokenSecuritySnapshot {
    GMGNTokenSecuritySnapshot(
      openSource: "yes",
      ownerRenounced: "yes",
      isHoneypot: isHoneypot,
      mintRenounced: true,
      freezeRenounced: true,
      rugRatio: rugRatio,
      top10HolderRate: 0.2,
      devTeamHoldRate: nil,
      suspectedInsiderHoldRate: nil,
      washTrading: false,
      buyTax: 0,
      sellTax: 0
    )
  }
  let lowSafety = GMGNTradeSafetyEvaluator.assess(
    security: safetySnapshot(rugRatio: 0.05)
  )
  check(
    lowSafety.level == .low && lowSafety.allowsQuickBuy,
    "Low-risk token should allow quick buy"
  )
  let mediumSafety = GMGNTradeSafetyEvaluator.assess(
    security: safetySnapshot(rugRatio: 0.2)
  )
  check(
    mediumSafety.level == .medium && mediumSafety.allowsQuickBuy,
    "Medium-risk token should allow quick buy"
  )
  let highSafety = GMGNTradeSafetyEvaluator.assess(
    security: safetySnapshot(rugRatio: 0.31)
  )
  check(
    highSafety.level == .high && highSafety.allowsStandardBuy
      && !highSafety.allowsQuickBuy && highSafety.requiresAdditionalConfirmation,
    "High-risk token should require standard buy confirmation"
  )
  let honeypotSafety = GMGNTradeSafetyEvaluator.assess(
    security: safetySnapshot(rugRatio: 0.01, isHoneypot: "yes")
  )
  check(
    honeypotSafety.level == .blocked && !honeypotSafety.allowsStandardBuy,
    "Honeypot should block every buy mode"
  )
  let missingSafety = GMGNTradeSafetyEvaluator.assess(
    security: safetySnapshot(rugRatio: nil)
  )
  check(
    missingSafety.level == .blocked && !missingSafety.allowsQuickBuy,
    "Missing Rug data should block the full safety policy"
  )
  let quickMissingRugSafety = GMGNTradeSafetyEvaluator.assessQuickBuy(
    security: safetySnapshot(rugRatio: nil)
  )
  check(
    quickMissingRugSafety.level == .low && quickMissingRugSafety.allowsQuickBuy,
    "Quick buy should ignore a missing Rug score after honeypot passes"
  )
  let quickHighRugSafety = GMGNTradeSafetyEvaluator.assessQuickBuy(
    security: safetySnapshot(rugRatio: 0.9)
  )
  check(
    quickHighRugSafety.level == .low && quickHighRugSafety.allowsQuickBuy,
    "Quick buy should not use the Rug score as a blocker"
  )
  let quickHoneypotSafety = GMGNTradeSafetyEvaluator.assessQuickBuy(
    security: safetySnapshot(rugRatio: nil, isHoneypot: "yes")
  )
  check(
    quickHoneypotSafety.level == .blocked && !quickHoneypotSafety.allowsQuickBuy,
    "Quick buy must still block a known honeypot"
  )
  let missingHoneypotSafety = GMGNTradeSafetyEvaluator.assess(
    security: safetySnapshot(rugRatio: 0.01, isHoneypot: nil)
  )
  check(
    missingHoneypotSafety.level == .blocked && !missingHoneypotSafety.allowsQuickBuy,
    "Missing honeypot data should block every buy mode"
  )
  for chain in [GMGNChain.sol, .eth, .base, .bsc] {
    let tokenAddress = chain == .sol
      ? "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
      : "0x1111111111111111111111111111111111111111"
    let walletAddress = chain == .sol
      ? "So11111111111111111111111111111111111111112"
      : "0x2222222222222222222222222222222222222222"
    let arguments = GMGNTradeClient.quoteArguments(
      GMGNTradeQuoteRequest(
        chain: chain,
        walletAddress: walletAddress,
        inputToken: GMGNNativeAsset.address(for: chain)!,
        outputToken: tokenAddress,
        inputAmountSmallestUnit: "1000000",
        slippagePercent: 12
      )
    )
    check(arguments.contains(chain.rawValue), "GMGN quote arguments must preserve \(chain.rawValue) chain")
  }
  check(
    TradeIntent.idempotencyKey(
      ruleID: "r", family: .evm, chain: .eth, address: "0x1111111111111111111111111111111111111111", windowStart: now
    ) != TradeIntent.idempotencyKey(
      ruleID: "r", family: .evm, chain: .bsc, address: "0x1111111111111111111111111111111111111111", windowStart: now
    ),
    "Trade idempotency must keep EVM networks separate"
  )

  let address = "So11111111111111111111111111111111111111112"
  let market = CATokenMarketSnapshot(
    chain: .sol,
    address: address,
    symbol: "SAFE",
    name: "Safe Fixture",
    priceUSD: 0.1,
    marketCapUSD: 1_000_000,
    liquidityUSD: 250_000,
    logoURL: nil,
    capturedAt: now
  )
  let security = GMGNTokenSecuritySnapshot(
    openSource: "yes",
    ownerRenounced: "yes",
    isHoneypot: "no",
    mintRenounced: true,
    freezeRenounced: true,
    rugRatio: 0.05,
    top10HolderRate: 0.2,
    devTeamHoldRate: nil,
    suspectedInsiderHoldRate: nil,
    washTrading: false,
    buyTax: 0,
    sellTax: 0
  )
  let eligibleContext = TradeRiskContext(
    configuration: TradeAutomationConfiguration(mode: .simulation),
    rule: rule,
    family: .solana,
    chain: .sol,
    triggeringGroup: "交易群 B",
    triggeringSender: "成员",
    mentionCount: 2,
    distinctGroupCount: 2,
    groupNames: ["交易群 A", "交易群 B"],
    market: market,
    security: security,
    holderCount: 10_000,
    now: now
  )
  check(TradeRiskEngine.evaluate(eligibleContext).isEligible, "Eligible trade risk context")

  var holderRule = rule
  holderRule.minimumHolderCount = 20_000
  var holderContext = eligibleContext
  holderContext.rule = holderRule
  holderContext.holderCount = 10_000
  let holderDecision = TradeRiskEngine.evaluate(holderContext)
  check(!holderDecision.isEligible, "Minimum holder count must be enforced")
  check(holderDecision.reasons.contains("持有人数量低于下限"), "Holder rejection should be explicit")

  var incompleteSecurity = eligibleContext
  incompleteSecurity.security = GMGNTokenSecuritySnapshot(
    openSource: nil,
    ownerRenounced: "yes",
    isHoneypot: "no",
    mintRenounced: true,
    freezeRenounced: true,
    rugRatio: 0.01,
    top10HolderRate: nil,
    devTeamHoldRate: nil,
    suspectedInsiderHoldRate: nil,
    washTrading: nil,
    buyTax: nil,
    sellTax: nil
  )
  let incompleteDecision = TradeRiskEngine.evaluate(incompleteSecurity)
  check(!incompleteDecision.isEligible, "Incomplete security data must reject automation")

  let simulation = TradeAutomationSimulator.run(
    configuration: TradeAutomationConfiguration(mode: .simulation),
    rule: rule,
    now: now
  )
  check(simulation.isEligible, "Local simulation should pass the default rule")
  check(simulation.reasons.isEmpty, "Passing simulation should not report rejection reasons")

  var simulationOff = TradeAutomationConfiguration(mode: .off)
  simulationOff.emergencyStopped = false
  let stoppedSimulation = TradeAutomationSimulator.run(
    configuration: simulationOff,
    rule: rule,
    now: now
  )
  check(!stoppedSimulation.isEligible, "Simulation must honor the global off mode")
  check(stoppedSimulation.reasons.contains("交易自动化已关闭"), "Simulation should explain off mode")

  let lowSpendSimulation = TradeAutomationSimulator.run(
    configuration: TradeAutomationConfiguration(mode: .simulation, maximumDailySpendUSD: 10),
    rule: rule,
    now: now
  )
  check(!lowSpendSimulation.isEligible, "Simulation should exercise the daily spend cap")
  check(
    lowSpendSimulation.reasons.contains("预计支出超过每日金额上限"),
    "Simulation should explain a daily spend rejection"
  )

  for chain in [GMGNChain.sol, .eth, .base, .bsc] {
    var chainContext = eligibleContext
    chainContext.chain = chain
    chainContext.family = chain == .sol ? .solana : .evm
    chainContext.rule.allowedChains = [chain]
    chainContext.market = CATokenMarketSnapshot(
      chain: chain,
      address: chain == .sol
        ? "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
        : "0x1111111111111111111111111111111111111111",
      symbol: "SAFE",
      name: "Safe Fixture",
      priceUSD: 0.1,
      marketCapUSD: 1_000_000,
      liquidityUSD: 250_000,
      logoURL: nil,
      capturedAt: now
    )
    check(
      TradeRiskEngine.evaluate(chainContext).isEligible,
      "Trade risk engine should support \(chain.rawValue)"
    )
  }

  var ambiguous = eligibleContext
  ambiguous.chain = nil
  let ambiguousDecision = TradeRiskEngine.evaluate(ambiguous)
  check(!ambiguousDecision.isEligible, "Ambiguous chain must reject trading")
  check(ambiguousDecision.reasons.contains("网络无法唯一识别"), "Ambiguous chain reason")

  var honeypot = eligibleContext
  honeypot.security = GMGNTokenSecuritySnapshot(
    openSource: "yes",
    ownerRenounced: nil,
    isHoneypot: "yes",
    mintRenounced: nil,
    freezeRenounced: nil,
    rugRatio: 0.01,
    top10HolderRate: nil,
    devTeamHoldRate: nil,
    suspectedInsiderHoldRate: nil,
    washTrading: nil,
    buyTax: nil,
    sellTax: nil
  )
  check(!TradeRiskEngine.evaluate(honeypot).isEligible, "Honeypot must reject trading")

  var cooling = eligibleContext
  cooling.lastIntentForTokenAt = now.addingTimeInterval(-60)
  check(!TradeRiskEngine.evaluate(cooling).isEligible, "Token cooldown must reject trading")

  var dailyLimited = eligibleContext
  dailyLimited.dailyIntentCount = dailyLimited.configuration.maximumDailyIntents
  check(!TradeRiskEngine.evaluate(dailyLimited).isEligible, "Daily limit must reject trading")

  var multiChain = rule
  multiChain.allowedChains = [.sol, .eth]
  check(!multiChain.validationIssues.isEmpty, "One rule cannot mix native-asset chains")
  var invertedMarketCap = rule
  invertedMarketCap.maximumMarketCapUSD = invertedMarketCap.minimumMarketCapUSD - 1
  check(
    invertedMarketCap.validationIssues.contains("最高市值不能低于最低市值"),
    "Trade rule must reject an inverted market-cap range"
  )

  var invalidStop = rule
  invalidStop.protectionOrders = [
    TradeProtectionOrder(kind: .stopLoss, triggerPercent: 100, sellPercent: 100)
  ]
  check(
    invalidStop.validationIssues.contains("保护单：止损下跌比例必须在 1% 到 99% 之间"),
    "A 100% stop loss must be rejected"
  )

  var overSelling = rule
  overSelling.protectionOrders = [
    TradeProtectionOrder(kind: .takeProfit, triggerPercent: 100, sellPercent: 60),
    TradeProtectionOrder(kind: .takeProfit, triggerPercent: 200, sellPercent: 60)
  ]
  check(
    overSelling.validationIssues.contains("止盈卖出比例合计不能超过 100%"),
    "Take-profit sell percentages must not exceed the full position"
  )
}

@MainActor
private func testGMGNTradeClient() async {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("wxfomo-gmgn-trade-selftest-\(UUID().uuidString)", isDirectory: true)
  let executableURL = directory.appendingPathComponent("gmgn-cli")
  let callsURL = directory.appendingPathComponent("calls")
  let portfolioTimeoutURL = directory.appendingPathComponent("portfolio-timeout")
  defer { try? FileManager.default.removeItem(at: directory) }
  let script = #"""
    #!/bin/sh
    printf '%s\n' "$*" >> 'CALLS_PATH'
    printf 'NODE_OPTIONS=%s\n' "$NODE_OPTIONS" >> 'CALLS_PATH'
    printf 'AUTOMATED=%s\n' "$GMGN_ALLOW_AUTOMATED_TRADES" >> 'CALLS_PATH'
    if [ "$1" = "config" ]; then
      exit 0
    fi
    if [ "$1" = "swap" ] && [ "$2" = "--help" ]; then
      printf '%s' 'Usage: gmgn-cli swap [options] --yes'
      exit 0
    fi
    if [ "$1" = "swap" ]; then
      if [ "$GMGN_ALLOW_AUTOMATED_TRADES" != "1" ]; then
        exit 96
      fi
      printf '%s' '{"data":{"order_id":"fixture-submission","status":"pending"}}'
      exit 0
    fi
    if [ "$1" = "multi-swap" ]; then
      exit 97
    fi
    if [ "$1" = "portfolio" ] && [ "$2" = "info" ]; then
      if [ -f 'PORTFOLIO_TIMEOUT_PATH' ]; then
        printf '%s' 'ConnectTimeoutError: openapi.gmgn.ai:443' >&2
        exit 1
      fi
      printf '%s' '{"wallets":[{"chain":"arc","address":"0xb04e000000000000000000000000000000007853","balances":[]},{"chain":"base","address":"0xb04e000000000000000000000000000000007853","balances":[{"symbol":"ETH","token_address":"0x4200000000000000000000000000000000000006","balance":"0.00125","usd_value":""}]},{"chain":"bsc","address":"0xb04e000000000000000000000000000000007853","balances":[{"symbol":"BNB","token_address":"0x0000000000000000000000000000000000000000","balance":"0.25","usd_value":"125.50"}]},{"chain":"eth","address":"0xb04e000000000000000000000000000000007853","balances":[{"symbol":"ETH","token_address":"0x0000000000000000000000000000000000000000","balance":"0.000000877498414775","usd_value":""}]},{"chain":"robinhood","address":"0xb04e000000000000000000000000000000007853","balances":[]},{"chain":"sol","address":"So11111111111111111111111111111111111111112","balances":[{"symbol":"SOL","token_address":"So11111111111111111111111111111111111111112","balance":"1.25","usd_value":""}],"private_key":"must-not-leak"},{"chain":"stable","address":"0xb04e000000000000000000000000000000007853","balances":[]}]}'
      exit 0
    fi
    if [ "$1" = "portfolio" ] && [ "$2" = "token-balance" ]; then
      printf '%s' '{"balances":[{"wallet_address":"0xb04e000000000000000000000000000000007853","token_address":"0x0000000000000000000000000000000000000000","balance":"0.00749485858724257","decimal":0,"height":51368896,"tx_index":0}]}'
      exit 0
    fi
    if [ "$1" = "order" ] && [ "$2" = "quote" ]; then
      case " $* " in
        *" --chain robinhood "*)
          printf '%s' '{"data":{"input_token":"0x0000000000000000000000000000000000000000","output_token":"0x5a8625d314fdd298101d87932a784b756a401e18","input_amount":"1000000000000000","output_amount":"1731211067974682000000","min_output_amount":"1500000000000000000000","slippage":12}}'
          exit 0
          ;;
      esac
      printf '%s' '{"data":{"input_token":"So11111111111111111111111111111111111111112","output_token":"EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v","input_amount":"10000000","output_amount":"123456","min_output_amount":"110000","slippage":12}}'
      exit 0
    fi
    if [ "$1" = "order" ] && [ "$2" = "get" ]; then
      printf '%s' '{"data":{"order_id":"fixture-order","status":"confirmed","hash":"fixture-hash","strategy_order_id":"fixture-strategy","report":{"input_token":"0x0000000000000000000000000000000000000000","input_token_decimals":18,"swap_mode":"ExactIn","input_amount":"1000000000000000","output_token":"0x5a8625d314fdd298101d87932a784b756a401e18","output_token_decimals":18,"output_amount":"1731211067974682000000","price":"0.000000577630367","price_usd":"0.0021","height":51368896,"order_height":51368890,"gas_native":"0.000314214861284001","gas_usd":"1.02"}}}'
      exit 0
    fi
    exit 2
    """#
    .replacingOccurrences(of: "CALLS_PATH", with: callsURL.path)
    .replacingOccurrences(of: "PORTFOLIO_TIMEOUT_PATH", with: portfolioTimeoutURL.path)

  do {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    try script.write(to: executableURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
    let client = GMGNTradeClient(executableURL: executableURL)
    let configurationState = await client.configurationState()
    check(configurationState == .ready, "GMGN trade configuration check")
    check(
      GMGNCLIProcessEnvironment.nodeOptions(merging: nil)
        == "--dns-result-order=ipv4first",
      "GMGN process enables IPv4-first DNS"
    )
    check(
      GMGNCLIProcessEnvironment.nodeOptions(
        merging: "--max-old-space-size=512 --dns-result-order=verbatim"
      ) == "--max-old-space-size=512 --dns-result-order=ipv4first",
      "GMGN process replaces conflicting DNS order without dropping other Node options"
    )
    check(
      GMGNCLIError.networkUnavailable(
        "ConnectTimeoutError: openapi.gmgn.ai:443"
      ).localizedDescription == "GMGN 连接超时，请稍后重试。",
      "GMGN transport errors hide raw host and HTTPS port"
    )
    check(
      GMGNTradeClient.portfolioInfoArguments == ["portfolio", "info", "--raw"],
      "GMGN portfolio argument construction"
    )
    check(
      GMGNTradeClient.robinhoodNativeBalanceArguments(
        walletAddress: "0xB04E000000000000000000000000000000007853"
      ) == [
        "portfolio", "token-balance", "--chain", "robinhood", "--wallet",
        "0xb04e000000000000000000000000000000007853", "--token",
        GMGNTradeClient.robinhoodNativeTokenAddress, "--raw",
      ],
      "GMGN Robinhood native balance argument construction"
    )
    check(
      GMGNTradeClient.tokenBalanceArguments(
        chain: .robinhood,
        walletAddress: "0xB04E000000000000000000000000000000007853",
        tokenAddress: "0x5A8625D314FDD298101D87932A784B756A401E18"
      ) == [
        "portfolio", "token-balance", "--chain", "robinhood", "--wallet",
        "0xb04e000000000000000000000000000000007853", "--token",
        "0x5a8625d314fdd298101d87932a784b756a401e18", "--raw",
      ],
      "GMGN token balance argument construction"
    )
    check(
      GMGNTokenAmount.smallestUnit(
        humanBalance: "1731.21106797468202059",
        percent: 50,
        decimals: 18
      ) == "865605533987341010295",
      "GMGN percentage sell amount rounds down in token smallest units"
    )
    let firstFetchDate = Date(timeIntervalSince1970: 1_940_000_050)
    let portfolio = try await client.portfolioInfo(now: firstFetchDate)
    check(portfolio.wallets.count == 7, "GMGN linked network wallet parsing")
    let portfolioRoundTrip = try JSONDecoder().decode(
      GMGNPortfolioInfoSnapshot.self,
      from: JSONEncoder().encode(portfolio)
    )
    check(portfolioRoundTrip == portfolio, "GMGN portfolio snapshot persists locally")
    let solWallet = portfolio.wallets.first(where: { $0.chainID == "sol" })
    let evmWallet = portfolio.wallets.first(where: { $0.chainID == "eth" })
    let robinhoodWallet = portfolio.wallets.first(where: { $0.chainID == "robinhood" })
    check(solWallet?.chain == .sol, "GMGN linked wallet chain parsing")
    check(
      solWallet?.primaryAddress == "So11111111111111111111111111111111111111112",
      "GMGN linked wallet address parsing"
    )
    check(
      evmWallet?.primaryAddress == "0xb04e000000000000000000000000000000007853",
      "GMGN EVM wallet address parsing"
    )
    check(solWallet?.primaryAddress != evmWallet?.primaryAddress, "GMGN chain wallets stay distinct")
    check(
      solWallet?.balances.first?.symbol == "SOL"
        && solWallet?.balances.first?.balance == "1.25"
        && solWallet?.balances.first?.usdValue == nil,
      "GMGN structured balance parsing omits blank USD values"
    )
    check(
      portfolio.wallets.first(where: { $0.chainID == "bsc" })?.balances.first?.usdValue
        == "125.50",
      "GMGN structured USD balance parsing"
    )
    check(
      robinhoodWallet?.balances.first?.symbol == "ETH"
        && robinhoodWallet?.balances.first?.balance == "0.00749485858724257"
        && robinhoodWallet?.balances.first?.tokenAddress
          == GMGNTradeClient.robinhoodNativeTokenAddress,
      "GMGN Robinhood native balance fallback"
    )
    check(
      portfolio.wallets.first(where: { $0.chainID == "arc" })?.localizedChainTitle == "Arc"
        && portfolio.wallets.first(where: { $0.chainID == "stable" })?.localizedChainTitle
          == "Stable",
      "GMGN extended network titles"
    )
    check(
      solWallet?.fields.contains { $0.path.lowercased().contains("private_key") }
        == false,
      "GMGN portfolio output must filter credential fields"
    )
    let cachedPortfolio = try await client.portfolioInfo(
      now: firstFetchDate.addingTimeInterval(10)
    )
    check(cachedPortfolio.fetchedAt == firstFetchDate, "GMGN portfolio uses 30 second cache")
    let refreshedPortfolio = try await client.portfolioInfo(
      now: firstFetchDate.addingTimeInterval(11),
      forceRefresh: true
    )
    check(
      refreshedPortfolio.fetchedAt == firstFetchDate.addingTimeInterval(11),
      "GMGN portfolio manual refresh bypasses cache"
    )
    let portfolioCalls = (try? String(contentsOf: callsURL, encoding: .utf8))?
      .split(separator: "\n")
      .filter { $0 == "portfolio info --raw" }
      .count
    check(portfolioCalls == 2, "GMGN portfolio cache avoids duplicate CLI calls")
    let robinhoodBalanceCalls = (try? String(contentsOf: callsURL, encoding: .utf8))?
      .split(separator: "\n")
      .filter { $0.hasPrefix("portfolio token-balance --chain robinhood") }
      .count
    check(
      robinhoodBalanceCalls == 2,
      "GMGN Robinhood balance fallback follows portfolio cache and refresh"
    )
    try Data().write(to: portfolioTimeoutURL)
    do {
      _ = try await client.portfolioInfo(forceRefresh: true)
      failures.append("GMGN ConnectTimeoutError should fail portfolio refresh")
    } catch {
      check(
        error.localizedDescription == "GMGN 连接超时，请稍后重试。",
        "GMGN portfolio timeout hides raw host and HTTPS port"
      )
    }
    let request = GMGNTradeQuoteRequest(
      chain: .sol,
      walletAddress: "So11111111111111111111111111111111111111112",
      inputToken: "So11111111111111111111111111111111111111112",
      outputToken: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
      inputAmountSmallestUnit: "10000000",
      slippagePercent: 12
    )
    let arguments = GMGNTradeClient.quoteArguments(request)
    check(arguments.prefix(2) == ["order", "quote"], "GMGN quote argument construction")
    check(!arguments.contains("swap") && !arguments.contains("--yes"), "Quote cannot become a swap")
    let swapArguments = GMGNTradeClient.swapArguments(
      GMGNTradeSwapRequest(
        chain: .sol,
        walletAddress: request.walletAddress,
        inputToken: request.inputToken,
        outputToken: request.outputToken,
        inputAmountSmallestUnit: request.inputAmountSmallestUnit,
        slippagePercent: request.slippagePercent
      )
    )
    check(swapArguments.prefix(2) == ["swap", "--chain"], "GMGN swap argument construction")
    check(swapArguments.contains("--raw"), "GMGN swap requests raw output")
    check(!swapArguments.contains("--yes"), "GMGN swap uses the current CLI contract")
    check(
      GMGNTradeClient.swapArguments(
        GMGNTradeSwapRequest(
          chain: .sol,
          walletAddress: request.walletAddress,
          inputToken: request.inputToken,
          outputToken: request.outputToken,
          inputAmountSmallestUnit: request.inputAmountSmallestUnit,
          slippagePercent: request.slippagePercent
        ),
        includeYes: true
      ).contains("--yes"),
      "GMGN swap should opt in explicitly when the installed CLI supports --yes"
    )
    let robinhoodRequest = GMGNTradeQuoteRequest(
      chain: .robinhood,
      walletAddress: "0xb04e000000000000000000000000000000007853",
      inputToken: GMGNTradeClient.robinhoodNativeTokenAddress,
      outputToken: "0x5a8625d314fdd298101d87932a784b756a401e18",
      inputAmountSmallestUnit: "1000000000000000",
      slippagePercent: 12
    )
    let robinhoodSwapArguments = GMGNTradeClient.swapArguments(
      GMGNTradeSwapRequest(
        chain: robinhoodRequest.chain,
        walletAddress: robinhoodRequest.walletAddress,
        inputToken: robinhoodRequest.inputToken,
        outputToken: robinhoodRequest.outputToken,
        inputAmountSmallestUnit: robinhoodRequest.inputAmountSmallestUnit,
        slippagePercent: robinhoodRequest.slippagePercent
      ),
      includeYes: true
    )
    check(
      !robinhoodSwapArguments.contains("--anti-mev"),
      "GMGN Robinhood swap must use the standard route"
    )
    let sellArguments = GMGNTradeClient.swapArguments(
      GMGNTradeSwapRequest(
        chain: .robinhood,
        walletAddress: robinhoodRequest.walletAddress,
        inputToken: robinhoodRequest.outputToken,
        outputToken: robinhoodRequest.inputToken,
        inputAmountSmallestUnit: "1731211067974682020590",
        inputPercent: 100,
        slippagePercent: 12,
        antiMEV: false
      )
    )
    check(
      sellArguments.contains("--percent") && sellArguments.contains("100")
        && !sellArguments.contains("--amount"),
      "GMGN percentage sell submits percent without an exact amount flag"
    )
    check(
      GMGNNativeAsset.address(for: .robinhood) == GMGNTradeClient.robinhoodNativeTokenAddress
        && GMGNNativeAsset.symbol(for: .robinhood) == "ETH"
        && GMGNNativeAsset.smallestUnitAmount(0.001, chain: .robinhood)
          == "1000000000000000",
      "GMGN Robinhood native ETH conversion"
    )
    let quoteDate = Date(timeIntervalSince1970: 1_940_000_100)
    async let firstQuoteRequest = client.quote(request, now: quoteDate)
    async let duplicateQuoteRequest = client.quote(request, now: quoteDate)
    let (quote, duplicateQuote) = try await (firstQuoteRequest, duplicateQuoteRequest)
    check(quote.outputAmount == "123456", "GMGN quote response parsing")
    check(quote == duplicateQuote, "Concurrent identical quotes should share one CLI request")
    let reusedQuote = try await client.quote(
      request,
      now: quoteDate.addingTimeInterval(1)
    )
    check(
      reusedQuote.quotedAt == quote.quotedAt,
      "Identical quotes should reuse the short-lived result"
    )
    check(
      quote.matches(request, now: Date(timeIntervalSince1970: 1_940_000_110)),
      "GMGN quote must bind the exact request within its validity window"
    )
    var changedRequest = request
    changedRequest = GMGNTradeQuoteRequest(
      chain: request.chain,
      walletAddress: request.walletAddress,
      inputToken: request.inputToken,
      outputToken: request.outputToken,
      inputAmountSmallestUnit: "20000000",
      slippagePercent: request.slippagePercent
    )
    check(
      !quote.matches(changedRequest, now: Date(timeIntervalSince1970: 1_940_000_110)),
      "GMGN quote must reject a changed amount"
    )
    check(
      !quote.matches(request, now: Date(timeIntervalSince1970: 1_940_000_131)),
      "GMGN quote must expire after thirty seconds"
    )
    let robinhoodQuote = try await client.quote(robinhoodRequest)
    check(
      robinhoodQuote.chain == .robinhood
        && robinhoodQuote.outputAmount == "1731211067974682000000",
      "GMGN Robinhood quote is accepted"
    )
    do {
      _ = try await client.submitSwap(
        GMGNTradeSwapRequest(
          chain: robinhoodRequest.chain,
          walletAddress: robinhoodRequest.walletAddress,
          inputToken: robinhoodRequest.inputToken,
          outputToken: robinhoodRequest.outputToken,
          inputAmountSmallestUnit: robinhoodRequest.inputAmountSmallestUnit,
          slippagePercent: robinhoodRequest.slippagePercent
        ),
        confirmedByUser: false
      )
      failures.append("GMGN submit must reject a missing user authorization")
    } catch {
      check(
        error.localizedDescription.contains("必须经过用户确认"),
        "GMGN submit rejects a missing user authorization before launching the CLI"
      )
    }
    let submission = try await client.submitSwap(
      GMGNTradeSwapRequest(
        chain: robinhoodRequest.chain,
        walletAddress: robinhoodRequest.walletAddress,
        inputToken: robinhoodRequest.inputToken,
        outputToken: robinhoodRequest.outputToken,
        inputAmountSmallestUnit: robinhoodRequest.inputAmountSmallestUnit,
        slippagePercent: robinhoodRequest.slippagePercent
      ),
      confirmedByUser: true
    )
    check(
      submission.orderID == "fixture-submission" && submission.status == "pending",
      "GMGN submit returns the order before confirmation polling"
    )
    let order = try await client.order(id: "fixture-order", chain: .sol)
    check(order.status == "confirmed", "GMGN order state parsing")
    check(order.strategyOrderID == "fixture-strategy", "GMGN strategy state parsing")
    check(
      order.report?.inputAmountNative == "0.001"
        && order.report?.outputAmountNative == "1731.211067974682"
        && order.report?.gasNative == "0.000314214861284001"
        && order.report?.height == 51_368_896,
      "GMGN full execution report parsing and human-unit conversion"
    )
    let legacyReport = try JSONDecoder().decode(
      GMGNTradeExecutionReport.self,
      from: Data(
        #"{"inputDecimals":18,"inputAmount":"1000000000000000","outputDecimals":18,"outputAmount":"1731211067974682020590","blockHeight":51474996}"#.utf8
      )
    )
    check(
      legacyReport.inputAmountNative == "0.001"
        && legacyReport.outputAmountNative == "1731.21106797468202059"
        && legacyReport.height == 51_474_996,
      "Legacy execution receipt field names remain readable"
    )
    let calls = (try? String(contentsOf: callsURL, encoding: .utf8)) ?? ""
    let solQuoteCalls = calls.split(whereSeparator: \.isNewline).filter {
      $0.hasPrefix("order quote --chain sol")
    }.count
    check(solQuoteCalls == 1, "Identical quote requests should launch gmgn-cli once")
    check(
      calls.split(whereSeparator: \.isNewline).contains {
        $0.contains("NODE_OPTIONS=") && $0.contains("--dns-result-order=ipv4first")
      },
      "GMGN child process receives IPv4-first Node options"
    )
    let submittedCall = calls.split(whereSeparator: \.isNewline).first {
      $0.hasPrefix("swap --chain robinhood")
    }
    check(
      submittedCall?.contains("--yes") == true,
      "GMGN authorized submit opts into the CLI confirmation contract"
    )
    check(
      calls.split(whereSeparator: \.isNewline).contains { $0 == "AUTOMATED=1" },
      "GMGN authorized submit enables the CLI code-level trade gate"
    )
  } catch {
    failures.append("GMGN trade client self-test threw: \(error.localizedDescription)")
  }
}

@MainActor
private func testTradeAutomationStore() async {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("wxfomo-trade-store-selftest-\(UUID().uuidString)", isDirectory: true)
  let databaseURL = directory.appendingPathComponent("workspace.sqlite3")
  defer { try? FileManager.default.removeItem(at: directory) }
  let now = Date(timeIntervalSince1970: 1_950_000_000)
  do {
    let store = try WorkspaceStore(databaseURL: databaseURL)
    let configuration = try await store.saveTradeAutomationConfiguration(
      TradeAutomationConfiguration(mode: .simulation),
      now: now
    )
    check(configuration.mode == .simulation, "Trade configuration persistence")
    let rule = try await store.saveTradeAutomationRule(
      TradeAutomationRule(id: "trade-selftest-rule", createdAt: now, updatedAt: now),
      now: now
    )
    let storedRules = try await store.tradeAutomationRules()
    check(storedRules == [rule], "Trade rule round trip")
    let intent = TradeIntent(
      id: "trade-selftest-intent",
      idempotencyKey: "trade:selftest-key",
      ruleID: rule.id,
      state: .simulated,
      chain: .sol,
      family: .solana,
      tokenAddress: "So11111111111111111111111111111111111111112",
      tokenSymbol: "FIX",
      sourceEventIDs: ["trade-source"],
      sourceGroups: ["群 A", "群 B"],
      mentionCount: 2,
      distinctGroupCount: 2,
      inputToken: GMGNNativeAsset.address(for: .sol),
      inputAmountNative: 0.01,
      inputAmountSmallestUnit: "10000000",
      executionReport: GMGNTradeExecutionReport(
        inputTokenDecimals: 9,
        inputAmount: "10000000",
        outputTokenDecimals: 6,
        outputAmount: "123456789",
        gasNative: "0.00001"
      ),
      createdAt: now,
      updatedAt: now
    )
    let inserted = try await store.insertTradeIntent(intent)
    var duplicateInput = intent
    duplicateInput.id = "trade-selftest-duplicate"
    let duplicate = try await store.insertTradeIntent(duplicateInput)
    check(inserted.id == duplicate.id, "Trade intent insert must be idempotent")
    let storedIntents = try await store.tradeIntents()
    check(storedIntents.count == 1, "Trade idempotency row count")
    check(
      storedIntents.first?.executionReport?.outputAmountNative == "123.456789",
      "Trade execution report persists in the audit record"
    )
    check(storedIntents.first?.resolvedSide == .buy, "Trade side persists as buy")
    var legacyObject = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(intent)
    ) as! [String: Any]
    legacyObject.removeValue(forKey: "side")
    legacyObject.removeValue(forKey: "sourceEventIDs")
    legacyObject.removeValue(forKey: "sourceGroups")
    legacyObject.removeValue(forKey: "mentionCount")
    legacyObject.removeValue(forKey: "distinctGroupCount")
    let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
    let legacyIntent = try JSONDecoder().decode(TradeIntent.self, from: legacyData)
    check(
      legacyIntent.resolvedSide == .buy && legacyIntent.mentionCount == 1,
      "Legacy trade records decode with safe defaults"
    )
    let ruleCount = try await store.tradeIntentCount(
      ruleID: rule.id,
      since: now.addingTimeInterval(-1)
    )
    check(ruleCount == 1, "Trade rule daily count")
    let latestIntentDate = try await store.latestTradeIntentDate(
      family: .solana,
      tokenAddress: intent.tokenAddress
    )
    check(latestIntentDate == now, "Trade token cooldown lookup")
    let metrics = try await store.tradeAutomationMetrics(now: now)
    check(metrics.dailyIntentCount == 1, "Trade metrics daily count")
  } catch {
    failures.append("Trade automation store self-test threw: \(error.localizedDescription)")
  }
}

@MainActor
private func testWorkspaceStorePersistenceAndQueue() async {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("wxfomo-workspace-selftest-\(UUID().uuidString)", isDirectory: true)
  let databaseURL = directory.appendingPathComponent("workspace.sqlite3")
  defer { try? FileManager.default.removeItem(at: directory) }

  let baseDate = Date(timeIntervalSince1970: 1_910_000_000)
  let secret = "selftest-key-\(UUID().uuidString)-must-not-enter-sqlite"
  let provider: AIProviderConfiguration
  do {
    provider = try AIProviderConfiguration(
      configurationID: "workspace-provider",
      displayName: "Workspace self-test",
      kind: .openAIChatCompletions,
      model: "gpt-selftest",
      credentialReference: "workspace-selftest-configuration-reference"
    )
  } catch {
    failures.append("Workspace provider fixture creation threw: \(error.localizedDescription)")
    return
  }

  let credentialStore = SelfTestAICredentialStore()
  do {
    try credentialStore.storeAPIKey(secret, for: provider)
    let loadedSecret = try credentialStore.apiKey(for: provider)
    check(loadedSecret == secret, "Credential fixture should retain the API key outside SQLite")
  } catch {
    failures.append("Workspace credential fixture threw: \(error.localizedDescription)")
    return
  }

  var completedJobID: String?
  var crossGroupAddressAlertID: String?
  do {
    let store = try WorkspaceStore(databaseURL: databaseURL)
    check(store.capabilities.journalMode == "wal", "Workspace store must use WAL")
    check(store.capabilities.schemaVersion == WorkspaceStore.currentSchemaVersion, "Workspace schema version")

    let cachedAddress = "0x4200000000000000000000000000000000000006"
    let chainResolution = DexScreenerChainResolution(
      address: cachedAddress,
      selectedChain: .base,
      candidates: [
        DexScreenerChainCandidate(
          chain: .base,
          pairCount: 2,
          maxLiquidityUSD: 120_000,
          maxVolume24hUSD: 80_000
        )
      ],
      resolvedAt: baseDate
    )
    _ = try await store.saveDexScreenerChainResolution(chainResolution, now: baseDate)
    let cachedResolution = try await store.dexScreenerChainResolution(
      address: cachedAddress.uppercased(),
      now: baseDate.addingTimeInterval(60)
    )
    check(cachedResolution?.selectedChain == .base, "Persistent chain cache round trip")
    check(cachedResolution?.source == .persistentCache, "Persistent chain cache source")
    let expiredResolution = try await store.dexScreenerChainResolution(
      address: cachedAddress,
      now: baseDate.addingTimeInterval(DexScreenerChainResolver.persistentCacheTTL + 1)
    )
    check(expiredResolution == nil, "Persistent chain cache expiry")

    _ = try await store.saveProviderConfiguration(
      provider,
      makeDefault: true,
      now: baseDate
    )
    let loadedProvider = try await store.providerConfiguration(id: provider.configurationID)
    check(loadedProvider == provider, "Workspace provider configuration round trip")
    let defaultProvider = try await store.defaultProviderConfiguration()
    check(defaultProvider == provider, "Workspace default provider persistence")

    var duplicateStoreRejected = false
    do {
      _ = try WorkspaceStore(databaseURL: databaseURL)
    } catch let error as WorkspaceStoreError {
      if case .databaseAlreadyInUse = error {
        duplicateStoreRejected = true
      } else {
        throw error
      }
    }
    check(duplicateStoreRejected, "Workspace database must reject a concurrent owner")

    let enqueued = try await store.enqueueAnalysisJob(
      frozenRangeID: "workspace-direct-range",
      providerID: provider.configurationID,
      mode: .digest,
      maximumAttempts: 3,
      idempotencyKey: "workspace-direct-job",
      now: baseDate
    )
    let duplicate = try await store.enqueueAnalysisJob(
      frozenRangeID: "workspace-direct-range",
      providerID: provider.configurationID,
      mode: .digest,
      maximumAttempts: 3,
      idempotencyKey: "workspace-direct-job",
      now: baseDate
    )
    check(duplicate.jobID == enqueued.jobID, "Workspace enqueue must be idempotent")

    guard let claimed = try await store.claimNextRunnableJob(now: baseDate) else {
      failures.append("Workspace queue should return its pending job")
      return
    }
    check(claimed.jobID == enqueued.jobID, "Workspace queue claim identity")
    check(claimed.state == .running && claimed.attempt == 1, "Workspace queue claim state")

    let retryAt = baseDate.addingTimeInterval(10)
    let retried = try await store.reschedule(
      jobID: claimed.jobID,
      nextAttemptAt: retryAt,
      error: "Authorization: Bearer \(secret)",
      now: baseDate.addingTimeInterval(1)
    )
    check(retried.state == .retryWait, "Workspace retry state")
    check(retried.nextAttemptAt == retryAt, "Workspace retry schedule")
    check(retried.lastError?.contains(secret) == false, "Workspace retry error must redact credentials")

    guard let reclaimed = try await store.claimNextRunnableJob(now: retryAt) else {
      failures.append("Workspace queue should reclaim a due retry")
      return
    }
    check(reclaimed.jobID == enqueued.jobID, "Workspace retry claim identity")
    check(reclaimed.attempt == 2, "Workspace retry attempt count")

    let result = selfTestAnalysisResult(
      job: reclaimed,
      configuration: provider,
      sourceMessageIDs: ["workspace-direct-source"]
    )
    let completed = try await store.complete(
      jobID: reclaimed.jobID,
      result: result,
      now: retryAt.addingTimeInterval(1)
    )
    completedJobID = completed.jobID
    check(completed.state == .succeeded, "Workspace complete state")
    let storedResult = try await store.analysisResult(forJobID: completed.jobID)
    check(storedResult?.result.analysisID == result.analysisID, "Workspace result persistence")

    let cancellable = try await store.enqueueAnalysisJob(
      frozenRangeID: "workspace-cancel-range",
      providerID: provider.configurationID,
      mode: .importantInformation,
      idempotencyKey: "workspace-cancel-job",
      now: retryAt.addingTimeInterval(2)
    )
    let cancelled = try await store.cancel(
      jobID: cancellable.jobID,
      now: retryAt.addingTimeInterval(3)
    )
    check(cancelled.state == .cancelled, "Workspace cancel state")

    let firstAlert = try await store.recordAlert(
      severity: .information,
      title: "Workspace signal",
      sourceEventIDs: ["workspace-event-1"],
      deduplicationKey: "workspace-alert-key",
      cooldownInterval: 60,
      now: baseDate
    )
    let repeatedAlert = try await store.recordAlert(
      severity: .critical,
      title: "Workspace signal escalated",
      sourceEventIDs: ["workspace-event-1", "workspace-event-2"],
      deduplicationKey: "workspace-alert-key",
      cooldownInterval: 60,
      now: baseDate.addingTimeInterval(1)
    )
    check(firstAlert.disposition == .created, "Workspace alert creation")
    check(repeatedAlert.disposition == .coalesced, "Workspace alert cooldown deduplication")
    check(repeatedAlert.alert.alertID == firstAlert.alert.alertID, "Workspace alert dedupe identity")
    check(repeatedAlert.alert.occurrenceCount == 2, "Workspace alert occurrence count")
    check(repeatedAlert.alert.severity == .critical, "Workspace alert severity escalation")
    check(
      repeatedAlert.alert.sourceEventIDs == ["workspace-event-1", "workspace-event-2"],
      "Workspace alert source merge"
    )
    check(repeatedAlert.alert.body == nil, "Workspace alerts must not persist message bodies by default")
    let acknowledged = try await store.acknowledgeAlert(
      id: repeatedAlert.alert.alertID,
      at: baseDate.addingTimeInterval(2)
    )
    check(acknowledged.isAcknowledged, "Workspace alert acknowledgment")
    let unacknowledged = try await store.alerts(includeAcknowledged: false)
    check(unacknowledged.isEmpty, "Acknowledged workspace alert filtering")

    let evmAddress = "0x6982508145454ce325ddbe47a25d4ec3d2311933"
    let upperEVMAddress = "0x" + evmAddress.dropFirst(2).uppercased()
    guard let evmMatch = CryptoAddressDetector.matches(in: "CA \(evmAddress)").first,
      let upperEVMMatch = CryptoAddressDetector.matches(in: "CA \(upperEVMAddress)").first
    else {
      failures.append("Cross-group address fixtures should be detected")
      return
    }
    func addressEvent(id: String, group: String, address: String, offset: TimeInterval) -> MessageEvent {
      MessageEvent(
        eventID: id,
        group: group,
        senderDisplayName: "成员",
        content: "发现地址 \(address)",
        messageType: .text,
        observedAt: baseDate.addingTimeInterval(offset),
        senderConfidence: .notificationPayload,
        isFromSelf: false
      )
    }

    let sameGroupFirst = addressEvent(
      id: "address-event-1",
      group: "地址群 A",
      address: evmAddress,
      offset: 100
    )
    let sameGroupSecond = addressEvent(
      id: "address-event-2",
      group: "地址群 A",
      address: upperEVMAddress,
      offset: 101
    )
    let firstMention = try await store.recordCryptoAddressMention(evmMatch, event: sameGroupFirst)
    let repeatedSameGroup = try await store.recordCryptoAddressMention(
      upperEVMMatch,
      event: sameGroupSecond
    )
    let duplicateMention = try await store.recordCryptoAddressMention(evmMatch, event: sameGroupFirst)
    check(firstMention.disposition == .recorded, "First address mention should only be recorded")
    check(repeatedSameGroup.disposition == .recorded, "Same-group mentions must not trigger")
    check(duplicateMention.disposition == .duplicate, "Address mentions must be idempotent")

    let secondGroup = addressEvent(
      id: "address-event-3",
      group: "地址群 B",
      address: evmAddress,
      offset: 102
    )
    let triggerSnapshot = CATokenMarketSnapshot(
      chain: .base,
      address: evmAddress,
      symbol: "TEST",
      name: "Test Token",
      priceUSD: 0.0125,
      marketCapUSD: 1_250_000,
      liquidityUSD: 300_000,
      logoURL: nil,
      capturedAt: baseDate.addingTimeInterval(102),
      source: .dexScreener
    )
    let createdIncident = try await store.recordCryptoAddressMention(
      evmMatch,
      event: secondGroup,
      triggerSnapshot: triggerSnapshot
    )
    check(
      createdIncident.disposition == .incidentCreated,
      "Second distinct group should create an address incident"
    )
    check(createdIncident.incident?.groupCount == 2, "Address incident distinct group count")
    check(createdIncident.incident?.mentionCount == 3, "Address incident mention count")
    check(createdIncident.alert?.severity == .information, "Two-group address alert severity")
    check(
      createdIncident.alert?.body?.contains("TEST · Test Token · Base") == true
        && createdIncident.alert?.body?.contains("触发时市值 $1.2M") == true,
      "Cross-group alert should persist trigger token identity and market cap"
    )
    crossGroupAddressAlertID = createdIncident.alert?.alertID

    let thirdGroup = addressEvent(
      id: "address-event-4",
      group: "地址群 C",
      address: upperEVMAddress,
      offset: 103
    )
    let updatedIncident = try await store.recordCryptoAddressMention(
      upperEVMMatch,
      event: thirdGroup
    )
    check(
      updatedIncident.disposition == .incidentUpdated,
      "Third distinct group should update the active incident"
    )
    check(
      updatedIncident.alert?.alertID == crossGroupAddressAlertID,
      "Third group must update the same address alert"
    )
    check(updatedIncident.incident?.groupCount == 3, "Third group should raise group count")
    check(updatedIncident.incident?.mentionCount == 4, "Third group should raise mention count")
    check(updatedIncident.alert?.severity == .warning, "Three-group address alert severity")
    let mentionSummary = try await store.cryptoAddressMentionSummary(
      family: .evm,
      normalizedAddress: upperEVMAddress,
      start: baseDate.addingTimeInterval(99),
      end: baseDate.addingTimeInterval(104)
    )
    check(mentionSummary?.groupCount == 3, "Address summary should count distinct groups")

    let ethMatch = evmMatch.resolvingNetwork(.ethereum)
    let bscMatch = evmMatch.resolvingNetwork(.bsc)
    let ethMention = try await store.recordCryptoAddressMention(
      ethMatch,
      event: addressEvent(
        id: "address-event-eth",
        group: "Ethereum 群",
        address: evmAddress,
        offset: 104
      )
    )
    let bscMention = try await store.recordCryptoAddressMention(
      bscMatch,
      event: addressEvent(
        id: "address-event-bsc",
        group: "BSC 群",
        address: evmAddress,
        offset: 105
      )
    )
    check(ethMention.disposition == .recorded, "Ethereum address identity must be isolated")
    check(bscMention.disposition == .recorded, "BSC address identity must be isolated")
    let ethSummary = try await store.cryptoAddressMentionSummary(
      family: .evm,
      network: .ethereum,
      normalizedAddress: evmAddress,
      start: baseDate.addingTimeInterval(99),
      end: baseDate.addingTimeInterval(106)
    )
    let bscSummary = try await store.cryptoAddressMentionSummary(
      family: .evm,
      network: .bsc,
      normalizedAddress: evmAddress,
      start: baseDate.addingTimeInterval(99),
      end: baseDate.addingTimeInterval(106)
    )
    check(ethSummary?.groupNames == ["Ethereum 群"], "Ethereum summary must not merge BSC mentions")
    check(bscSummary?.groupNames == ["BSC 群"], "BSC summary must not merge Ethereum mentions")
    check(mentionSummary?.mentionCount == 4, "Address summary should count all mentions")
    check(
      mentionSummary?.groupNames == ["地址群 A", "地址群 B", "地址群 C"],
      "Address summary should retain first-seen group order"
    )

    let nextCycleFirst = addressEvent(
      id: "address-event-5",
      group: "地址群 D",
      address: evmAddress,
      offset: 26 * 60 * 60
    )
    let nextCycleSecond = addressEvent(
      id: "address-event-6",
      group: "地址群 E",
      address: evmAddress,
      offset: 26 * 60 * 60 + 1
    )
    let afterGap = try await store.recordCryptoAddressMention(evmMatch, event: nextCycleFirst)
    let newCycle = try await store.recordCryptoAddressMention(evmMatch, event: nextCycleSecond)
    check(afterGap.disposition == .recorded, "A 24-hour gap should close the prior activity cycle")
    check(newCycle.disposition == .incidentCreated, "A later cross-group cycle should create a new alert")
    check(
      newCycle.alert?.alertID != crossGroupAddressAlertID,
      "A later activity cycle must use a different alert"
    )
    let addressIncidents = try await store.crossGroupAddressIncidents()
    check(addressIncidents.count == 2, "Address incident cycle persistence")
    check(
      addressIncidents.filter { $0.status == .active }.count == 1
        && addressIncidents.filter { $0.status == .closed }.count == 1,
      "Address incident active and closed states"
    )

    let poolConfiguration = CAWatchPoolConfiguration(
      isEnabled: true,
      capacity: 10,
      minimumMarketCapUSD: 500_000,
      refreshIntervalSeconds: 120,
      graceAttemptCount: 2
    )
    _ = try await store.saveCAWatchPoolConfiguration(poolConfiguration, now: baseDate)
    let loadedPoolConfiguration = try await store.caWatchPoolConfiguration()
    check(
      loadedPoolConfiguration == poolConfiguration,
      "CA watch pool configuration round trip"
    )

    let marketSnapshot = CATokenMarketSnapshot(
      chain: .eth,
      address: evmAddress,
      symbol: "SELF",
      name: "Self Test Token",
      priceUSD: 0.25,
      marketCapUSD: 750_000,
      liquidityUSD: 125_000,
      logoURL: nil,
      capturedAt: baseDate.addingTimeInterval(104),
      source: .dexScreener
    )
    let poolItem = CAWatchPoolItem(
      family: .evm,
      network: .ethereum,
      normalizedAddress: evmAddress,
      chain: .eth,
      state: .watching,
      entrySnapshot: marketSnapshot,
      currentSnapshot: marketSnapshot,
      groupNames: ["地址群 A", "地址群 B"],
      firstSeenAt: baseDate.addingTimeInterval(100),
      latestSeenAt: baseDate.addingTimeInterval(103),
      updatedAt: baseDate.addingTimeInterval(105)
    )
    _ = try await store.saveCAWatchPoolItem(poolItem)
    let loadedPoolItems = try await store.caWatchPoolItems(states: [.watching])
    check(
      loadedPoolItems.first == poolItem,
      "CA watch pool item round trip"
    )

    let signalEnrichment = CASignalEnrichment(
      eventID: sameGroupFirst.eventID,
      family: .evm,
      normalizedAddress: evmAddress,
      state: .resolved,
      snapshot: marketSnapshot,
      attemptCount: 1,
      createdAt: baseDate.addingTimeInterval(100),
      updatedAt: baseDate.addingTimeInterval(104)
    )
    _ = try await store.saveCASignalEnrichment(signalEnrichment)
    let loadedSignalEnrichments = try await store.caSignalEnrichments(
      eventIDs: [sameGroupFirst.eventID]
    )
    check(
      loadedSignalEnrichments.first == signalEnrichment,
      "CA signal enrichment round trip"
    )

    let leakedWhileOpen = try workspaceArtifactsContain(secret, databaseURL: databaseURL)
    check(!leakedWhileOpen, "API keys must not appear in workspace SQLite artifacts")
  } catch {
    failures.append("Workspace store self-test threw: \(error.localizedDescription)")
    return
  }

  let lockURL = URL(fileURLWithPath: databaseURL.path + ".lock")
  check(
    FileManager.default.fileExists(atPath: lockURL.path),
    "Workspace lockfile should remain after releasing its flock"
  )

  do {
    let reopened = try WorkspaceStore(databaseURL: databaseURL)
    let defaultProvider = try await reopened.defaultProviderConfiguration()
    check(defaultProvider == provider, "Workspace provider must survive reopening")
    if let completedJobID {
      let completed = try await reopened.analysisJob(id: completedJobID)
      check(completed?.state == .succeeded, "Workspace job must survive reopening")
      let result = try await reopened.analysisResult(forJobID: completedJobID)
      check(result != nil, "Workspace analysis result must survive reopening")
    }
    if let crossGroupAddressAlertID {
      let alert = try await reopened.alert(id: crossGroupAddressAlertID)
      check(alert != nil, "Cross-group address alert must survive reopening")
      let incidents = try await reopened.crossGroupAddressIncidents()
      check(incidents.count == 2, "Cross-group address incidents must survive reopening")
    }
    let reopenedPoolConfiguration = try await reopened.caWatchPoolConfiguration()
    check(
      reopenedPoolConfiguration?.minimumMarketCapUSD == 500_000,
      "CA watch pool configuration must survive reopening"
    )
    let reopenedPoolItems = try await reopened.caWatchPoolItems(states: [.watching])
    check(
      reopenedPoolItems.first?.entrySnapshot?.symbol == "SELF",
      "CA watch pool item must survive reopening"
    )
    let reopenedSignalEnrichments = try await reopened.caSignalEnrichments(
      eventIDs: ["address-event-1"]
    )
    check(
      reopenedSignalEnrichments.first?.snapshot?.marketCapUSD == 750_000,
      "CA signal trigger snapshot must survive reopening"
    )
    let leakedAfterReopen = try workspaceArtifactsContain(secret, databaseURL: databaseURL)
    check(!leakedAfterReopen, "API keys must remain absent after workspace reopening")
  } catch {
    failures.append("Workspace reopen self-test threw: \(error.localizedDescription)")
  }
}

@MainActor
private func testAnalysisJobRunner() async {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("wxfomo-runner-selftest-\(UUID().uuidString)", isDirectory: true)
  let messageDatabaseURL = directory.appendingPathComponent("messages.sqlite3")
  let workspaceDatabaseURL = directory.appendingPathComponent("workspace.sqlite3")
  defer { try? FileManager.default.removeItem(at: directory) }

  let baseDate = Date(timeIntervalSince1970: 1_920_000_000)
  do {
    let provider = try AIProviderConfiguration(
      configurationID: "runner-provider",
      displayName: "Runner self-test",
      kind: .openAIChatCompletions,
      model: "gpt-runner-selftest",
      credentialReference: "runner-selftest-configuration-reference"
    )
    let messageStore = try MessageStore(databaseURL: messageDatabaseURL)
    let workspaceStore = try WorkspaceStore(databaseURL: workspaceDatabaseURL)
    let source = fixtureMessageEvent(
      id: "runner-source",
      content: "需要总结的消息",
      observedAt: baseDate,
      sequence: 1
    )
    _ = try await messageStore.insert(source)
    let frozen = try await messageStore.freeze(eventIDs: [source.eventID])
    _ = try await workspaceStore.saveProviderConfiguration(
      provider,
      makeDefault: true,
      now: baseDate
    )

    let clock = SelfTestAnalysisRunnerClock(now: baseDate)
    let runnerConfiguration = AnalysisJobRunnerConfiguration(
      pollIntervalSeconds: 1,
      retryBaseDelaySeconds: 5,
      retryMaximumDelaySeconds: 20,
      retryJitterFraction: 0,
      localeIdentifier: "zh_CN"
    )
    let retryRunner = try AnalysisJobRunner(
      messageStore: messageStore,
      workspaceStore: workspaceStore,
      providerFactory: SelfTestAnalysisProviderFactory(behavior: .retryableFailure),
      clock: clock,
      configuration: runnerConfiguration
    )
    let retryJob = try await workspaceStore.enqueueAnalysisJob(
      frozenRangeID: frozen.id,
      providerID: provider.configurationID,
      mode: .digest,
      maximumAttempts: 3,
      idempotencyKey: "runner-retry-job",
      now: baseDate
    )
    let retryOutcome = try await retryRunner.processNext()
    if case let .retryScheduled(jobID, nextAttemptAt, errorCode) = retryOutcome {
      check(jobID == retryJob.jobID, "Runner retry job identity")
      check(nextAttemptAt == baseDate.addingTimeInterval(5), "Runner retry backoff")
      check(errorCode == .transportRetryable, "Runner retry error classification")
    } else {
      failures.append("Runner should schedule retryable provider failures")
    }
    let retried = try await workspaceStore.analysisJob(id: retryJob.jobID)
    check(retried?.state == .retryWait, "Runner must persist retry_wait")
    check(retried?.attempt == 1, "Runner retry attempt count")
    check(
      retried?.lastError == AnalysisJobFailureCode.transportRetryable.rawValue,
      "Runner must persist only a stable retry code"
    )

    let cancelledRetry = try await retryRunner.cancel(jobID: retryJob.jobID)
    check(cancelledRetry.state == .cancelled, "Runner cancel must persist cancelled state")

    let successRunner = try AnalysisJobRunner(
      messageStore: messageStore,
      workspaceStore: workspaceStore,
      providerFactory: SelfTestAnalysisProviderFactory(behavior: .succeed),
      clock: clock,
      configuration: runnerConfiguration
    )
    let successJob = try await workspaceStore.enqueueAnalysisJob(
      frozenRangeID: frozen.id,
      providerID: provider.configurationID,
      mode: .digest,
      maximumAttempts: 2,
      idempotencyKey: "runner-success-job",
      now: baseDate
    )
    let successOutcome = try await successRunner.processNext()
    if case let .succeeded(jobID, analysisID) = successOutcome {
      check(jobID == successJob.jobID, "Runner success job identity")
      check(
        analysisID == "selftest-analysis-\(successJob.jobID)",
        "Runner success analysis identity"
      )
    } else {
      failures.append("Runner should complete a valid provider result")
    }
    let succeeded = try await workspaceStore.analysisJob(id: successJob.jobID)
    check(succeeded?.state == .succeeded, "Runner must persist succeeded state")
    let storedResult = try await workspaceStore.analysisResult(forJobID: successJob.jobID)
    check(storedResult?.result.requestID == successJob.jobID, "Runner result request linkage")
    check(
      storedResult?.result.provenance.sourceMessageIDs == [source.eventID],
      "Runner result source provenance"
    )

    let cancellable = try await workspaceStore.enqueueAnalysisJob(
      frozenRangeID: frozen.id,
      providerID: provider.configurationID,
      mode: .actionItems,
      idempotencyKey: "runner-cancel-job",
      now: baseDate
    )
    let cancelled = try await successRunner.cancel(jobID: cancellable.jobID)
    check(cancelled.state == .cancelled, "Runner pending job cancellation")
    let idleOutcome = try await successRunner.processNext()
    check(idleOutcome == .idle, "Runner should become idle after terminal jobs")
  } catch {
    failures.append("Analysis job runner self-test threw: \(error.localizedDescription)")
  }
}

private func testNotificationSoundPolicy() {
  let now = Date(timeIntervalSince1970: 2_000_000_000)
  let global = NotificationSoundRule(
    id: "global-ca",
    name: "Global CA",
    eventKind: .cryptoAddress,
    soundName: "Pop",
    priority: 50,
    cooldownInterval: 600
  )
  let group = NotificationSoundRule(
    id: "group-ca",
    name: "Group CA",
    eventKind: .cryptoAddress,
    groups: ["Alpha 群"],
    soundName: "Ping",
    priority: 50,
    cooldownInterval: 600
  )
  let sender = NotificationSoundRule(
    id: "sender-ca",
    name: "Sender CA",
    eventKind: .cryptoAddress,
    senders: ["Alice"],
    soundName: "Glass",
    priority: 50,
    cooldownInterval: 600
  )
  let combined = NotificationSoundRule(
    id: "combined-ca",
    name: "Combined CA",
    eventKind: .cryptoAddress,
    groups: ["Alpha 群"],
    senders: ["Alice"],
    soundName: "Hero",
    priority: 50,
    cooldownInterval: 600
  )
  let critical = NotificationSoundRule(
    id: "critical",
    name: "Critical",
    eventKind: .alertCritical,
    soundName: "Basso",
    priority: 100
  )
  let configuration = NotificationSoundConfiguration(
    rules: [global, group, sender, combined, critical]
  )
  let caEvent = NotificationSoundEvent(
    kind: .cryptoAddress,
    eventID: "event-1",
    group: "alpha 群",
    senderDisplayName: "alice",
    subjectID: "0x1234"
  )

  let specific = NotificationSoundPolicy.resolve(
    events: [caEvent],
    configuration: configuration,
    now: now
  )
  check(specific?.rule.id == combined.id, "Sound policy group+sender specificity")

  let criticalEvent = NotificationSoundEvent(
    kind: .alertCritical,
    eventID: "event-1",
    group: "Alpha 群",
    senderDisplayName: "Alice",
    subjectID: "risk-rule"
  )
  let urgent = NotificationSoundPolicy.resolve(
    events: [caEvent, criticalEvent],
    configuration: configuration,
    now: now
  )
  check(urgent?.rule.id == critical.id, "Sound policy priority before specificity")

  let cooling = NotificationSoundPolicy.resolve(
    events: [caEvent],
    configuration: configuration,
    lastPlayedAtByKey: [specific!.cooldownKey: now.addingTimeInterval(-30)],
    now: now
  )
  check(cooling == nil, "Sound policy cooldown must not fall back to a broader rule")

  var muted = configuration
  muted.mutedUntil = now.addingTimeInterval(60)
  check(
    NotificationSoundPolicy.resolve(
      events: [criticalEvent],
      configuration: muted,
      now: now
    ) == nil,
    "Sound policy temporary mute"
  )

  let defaultCA = NotificationSoundConfiguration.defaultRules.first {
    $0.id == "default.crypto-address"
  }
  check(defaultCA?.effectiveOutputMode == .speech, "Default CA rule should use speech")
  check(
    defaultCA?.effectiveSpeechAnnouncement.text
      == NotificationSoundEventKind.cryptoAddress.defaultSpeechText,
    "Default CA speech should use runtime sender and token details"
  )

  let legacyJSON = """
    {
      "isEnabled": true,
      "playWhileAppIsActive": true,
      "masterVolume": 0.8,
      "minimumInterval": 1.5,
      "rules": [
        {
          "id": "default.crypto-address",
          "name": "CA 出现",
          "isEnabled": true,
          "eventKind": "crypto_address",
          "groups": [],
          "senders": [],
          "soundName": "Pop",
          "volume": 0.72,
          "priority": 50,
          "cooldownInterval": 600
        },
        {
          "id": "custom-person-ca",
          "name": "Alice CA",
          "isEnabled": true,
          "eventKind": "crypto_address",
          "groups": ["Alpha 群"],
          "senders": ["Alice"],
          "soundName": "Ping",
          "volume": 0.8,
          "priority": 90,
          "cooldownInterval": 30
        }
      ]
    }
    """
  do {
    let decoded = try JSONDecoder().decode(
      NotificationSoundConfiguration.self,
      from: Data(legacyJSON.utf8)
    )
    check(decoded.rules.allSatisfy { $0.outputMode == nil }, "Legacy sound rules decode")
    let migrated = decoded.migratedForSpeechAnnouncements
    check(
      migrated.rules.first { $0.id == "default.crypto-address" }?.effectiveOutputMode == .speech,
      "Legacy built-in CA rule speech migration"
    )
    check(
      migrated.rules.first { $0.id == "custom-person-ca" }?.effectiveOutputMode == .sound,
      "Legacy custom person rule remains sound-only"
    )
    let legacySpecificSpeech = NotificationSoundConfiguration(
      rules: [
        NotificationSoundRule(
          id: "custom-legacy-ca-speech",
          name: "Specific CA speech",
          eventKind: .cryptoAddress,
          outputMode: .speech,
          soundName: "Ping",
          speechAnnouncement: NotificationSpeechAnnouncement(text: "发现 CA")
        )
      ]
    ).migratedForSpeechAnnouncements
    check(
      legacySpecificSpeech.rules[0].effectiveSpeechAnnouncement.text
        == NotificationSoundEventKind.cryptoAddress.defaultSpeechText,
      "Legacy custom CA default text should migrate to dynamic speech"
    )

    var configured = migrated
    configured.speech = NotificationSpeechConfiguration(
      provider: .system,
      voiceID: "legacy-voice-should-not-persist",
      fallbackToSystemVoice: false
    )
    var customRule = configured.rules[1]
    customRule.outputMode = .soundAndSpeech
    customRule.speechAnnouncement = NotificationSpeechAnnouncement(
      text: "Alice 发了 CA",
      rate: 1.15,
      volume: 0.7
    )
    configured.rules[1] = customRule
    let encodedSoundConfiguration = try JSONEncoder().encode(configured)
    let encodedSoundObject = try JSONSerialization.jsonObject(with: encodedSoundConfiguration)
      as? [String: Any]
    check(
      encodedSoundObject?["speech"] == nil,
      "Sound settings should not duplicate speech service configuration"
    )
    let roundTrip = try JSONDecoder().decode(
      NotificationSoundConfiguration.self,
      from: encodedSoundConfiguration
    )
    check(
      roundTrip.speech == NotificationSpeechConfiguration(),
      "Sound settings without embedded speech should use service defaults"
    )
    check(
      roundTrip.rules[1].effectiveOutputMode == .soundAndSpeech
        && roundTrip.rules[1].effectiveSpeechAnnouncement.text == "Alice 发了 CA",
      "Rule speech configuration round trip"
    )
  } catch {
    failures.append("Notification speech compatibility self-test threw: \(error.localizedDescription)")
  }
}

testMessageParser()
testSequenceDelta()
testStableHash()
testNotificationPayloadAndMapping()
testMessageEventOrdering()
testOCRGeometryExtraction()
await testNotificationMonitorRecovery()
await testNotificationMonitorDatabaseReset()
await testNotificationMonitorInPlaceUpdateRecovery()
await testNotificationMonitorGroupMismatchDiagnosis()
await testMessageStorePersistence()
await testMessageFlowAnalytics()
await testMessageManagementMetrics()
testRulesAndQuantification()
testAIProviderConfigurationSafety()
testFileConfigurationCenterStore()
testVolcengineSeedStreamParser()
testCryptoAddressDetection()
testWebLinkDetection()
testCryptoAddressDetectionAtRequestLimit()
testNotificationSoundPolicy()
testTradeAutomationRiskEngine()
await testDexScreenerChainResolver()
await testGMGNCLIClient()
await testGMGNTradeClient()
await testAIProviderConnectionTester()
await testRemoteAIAnalysisProviderStreaming()
await testWorkspaceStorePersistenceAndQueue()
await testTradeAutomationStore()
await testAnalysisJobRunner()

if failures.isEmpty {
  print("wxfomo-selftest: all checks passed")
} else {
  for failure in failures {
    FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
  }
  FileHandle.standardError.write(Data("\(failures.count) check(s) failed\n".utf8))
  exit(1)
}
