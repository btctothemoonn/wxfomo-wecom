import Foundation

public protocol AIAnalysisProviderFactory: Sendable {
  func makeProvider(
    configuration: AIProviderConfiguration
  ) throws -> any AIAnalysisProviding
}

public struct RemoteAIAnalysisProviderFactory: AIAnalysisProviderFactory, Sendable {
  private let credentialStore: any AICredentialStoring
  private let transport: any AIHTTPTransporting

  public init(
    credentialStore: any AICredentialStoring = FileConfigurationCenterStore(),
    transport: any AIHTTPTransporting = URLSessionAIHTTPTransport()
  ) {
    self.credentialStore = credentialStore
    self.transport = transport
  }

  public func makeProvider(
    configuration: AIProviderConfiguration
  ) throws -> any AIAnalysisProviding {
    try RemoteAIAnalysisProvider(
      configuration: configuration,
      credentialStore: credentialStore,
      transport: transport
    )
  }
}

public protocol AnalysisJobRunnerClock: Sendable {
  func now() async -> Date
  func sleep(for seconds: TimeInterval) async throws
  func randomUnitInterval() async -> Double
}

public struct SystemAnalysisJobRunnerClock: AnalysisJobRunnerClock, Sendable {
  public init() {}

  public func now() async -> Date { Date() }

  public func sleep(for seconds: TimeInterval) async throws {
    guard seconds > 0 else {
      try Task.checkCancellation()
      return
    }
    let maximumSeconds = Double(UInt64.max / 1_000_000_000)
    let nanoseconds = UInt64(min(seconds, maximumSeconds) * 1_000_000_000)
    try await Task.sleep(nanoseconds: nanoseconds)
  }

  public func randomUnitInterval() async -> Double {
    Double.random(in: 0...1)
  }
}

public enum AnalysisJobRunnerConfigurationError: Error, Equatable, Sendable {
  case invalidPollInterval
  case invalidRetryBaseDelay
  case invalidRetryMaximumDelay
  case invalidRetryJitterFraction
}

public struct AnalysisJobRunnerConfiguration: Equatable, Sendable {
  public var pollIntervalSeconds: TimeInterval
  public var retryBaseDelaySeconds: TimeInterval
  public var retryMaximumDelaySeconds: TimeInterval
  public var retryJitterFraction: Double
  public var localeIdentifier: String

  public init(
    pollIntervalSeconds: TimeInterval = 2,
    retryBaseDelaySeconds: TimeInterval = 2,
    retryMaximumDelaySeconds: TimeInterval = 5 * 60,
    retryJitterFraction: Double = 0.2,
    localeIdentifier: String = Locale.current.identifier
  ) {
    self.pollIntervalSeconds = pollIntervalSeconds
    self.retryBaseDelaySeconds = retryBaseDelaySeconds
    self.retryMaximumDelaySeconds = retryMaximumDelaySeconds
    self.retryJitterFraction = retryJitterFraction
    self.localeIdentifier = localeIdentifier
  }

  public func validate() throws {
    guard pollIntervalSeconds.isFinite, pollIntervalSeconds > 0 else {
      throw AnalysisJobRunnerConfigurationError.invalidPollInterval
    }
    guard retryBaseDelaySeconds.isFinite, retryBaseDelaySeconds > 0 else {
      throw AnalysisJobRunnerConfigurationError.invalidRetryBaseDelay
    }
    guard retryMaximumDelaySeconds.isFinite,
          retryMaximumDelaySeconds >= retryBaseDelaySeconds else {
      throw AnalysisJobRunnerConfigurationError.invalidRetryMaximumDelay
    }
    guard retryJitterFraction.isFinite, (0...1).contains(retryJitterFraction) else {
      throw AnalysisJobRunnerConfigurationError.invalidRetryJitterFraction
    }
  }
}

/// Stable, non-sensitive diagnostics persisted with an analysis job.
public enum AnalysisJobFailureCode: String, Codable, Equatable, Sendable {
  case frozenRangeNotFound = "frozen_range_not_found"
  case frozenRangeEmpty = "frozen_range_empty"
  case frozenRangeMissingBounds = "frozen_range_missing_bounds"
  case frozenRangeMembershipMismatch = "frozen_range_membership_mismatch"
  case frozenRangeTooManyMessages = "frozen_range_too_many_messages"
  case frozenRangeReadFailed = "frozen_range_read_failed"
  case providerConfigurationNotFound = "provider_configuration_not_found"
  case providerConfigurationReadFailed = "provider_configuration_read_failed"
  case providerFactoryFailed = "provider_factory_failed"
  case providerInvalidConfiguration = "provider_invalid_configuration"
  case providerCredentialUnavailable = "provider_credential_unavailable"
  case analysisRequestInvalid = "analysis_request_invalid"
  case unsupportedPromptVersion = "unsupported_prompt_version"
  case promptTooLarge = "prompt_too_large_512_kib"
  case requestEncodingFailed = "provider_request_encoding_failed"
  case transportRetryable = "provider_transport_retryable"
  case transportNotRetryable = "provider_transport_not_retryable"
  case httpRetryable = "provider_http_retryable"
  case httpNotRetryable = "provider_http_not_retryable"
  case responseTooLarge = "provider_response_too_large"
  case responseDecodingFailed = "provider_response_decoding_failed"
  case emptyResponse = "provider_empty_response"
  case modelRefused = "provider_model_refused"
  case outputIncomplete = "provider_output_incomplete"
  case providerCancelledUnexpectedly = "provider_cancelled_unexpectedly"
  case providerUnclassifiedFailure = "provider_unclassified_failure"
  case resultContractMismatch = "provider_result_contract_mismatch"
  case runnerStopped = "runner_stopped"
  case runnerInfrastructureFailure = "runner_infrastructure_failure"
}

public enum AnalysisJobRunnerOutcome: Equatable, Sendable {
  case idle
  case busy
  case succeeded(jobID: String, analysisID: String)
  case retryScheduled(
    jobID: String,
    nextAttemptAt: Date,
    errorCode: AnalysisJobFailureCode
  )
  case failed(jobID: String, errorCode: AnalysisJobFailureCode)
  case cancelled(jobID: String)
  case released(jobID: String)
}

public enum AnalysisJobRunnerError: Error, Equatable, Sendable {
  case alreadyProcessing
  case invalidDrainLimit
  case durableStateUnavailable
}

/// Serial durable worker for frozen-range AI analysis jobs.
///
/// The actor intentionally owns only one provider task. Calling `processNext`,
/// `drainAvailable`, or `run` while another driver is active never claims a
/// second job, preventing accidental concurrent billing.
public actor AnalysisJobRunner {
  public static let supportedPromptVersion = 1
  public static let maximumPromptBytes = 512 * 1_024

  private enum Driver {
    case single
    case drain
    case polling
  }

  private enum PreparationFailure: Error {
    case permanent(AnalysisJobFailureCode)
    case retryable(AnalysisJobFailureCode)
  }

  private enum ControlSignal: Error {
    case jobCancellationRequested
  }

  private let messageStore: MessageStore
  private let workspaceStore: WorkspaceStore
  private let providerFactory: any AIAnalysisProviderFactory
  private let clock: any AnalysisJobRunnerClock
  private let configuration: AnalysisJobRunnerConfiguration

  private var driver: Driver?
  private var stopRequested = false
  private var activeJobID: String?
  private var activeProviderTask: Task<AIAnalysisResult, Error>?
  private var activeSleepTask: Task<Void, Error>?
  private var cancellationRequestedJobIDs = Set<String>()

  public init(
    messageStore: MessageStore,
    workspaceStore: WorkspaceStore,
    providerFactory: any AIAnalysisProviderFactory = RemoteAIAnalysisProviderFactory(),
    clock: any AnalysisJobRunnerClock = SystemAnalysisJobRunnerClock(),
    configuration: AnalysisJobRunnerConfiguration = AnalysisJobRunnerConfiguration()
  ) throws {
    try configuration.validate()
    self.messageStore = messageStore
    self.workspaceStore = workspaceStore
    self.providerFactory = providerFactory
    self.clock = clock
    self.configuration = configuration
  }

  public var currentJobID: String? { activeJobID }

  @discardableResult
  public func processNext() async throws -> AnalysisJobRunnerOutcome {
    guard driver == nil else { return .busy }
    driver = .single
    stopRequested = false
    defer { driver = nil }
    return try await processOneClaimedJob()
  }

  /// Processes currently runnable work serially, up to the supplied safety cap.
  public func drainAvailable(maximumJobs: Int = 100) async throws
    -> [AnalysisJobRunnerOutcome]
  {
    guard maximumJobs > 0 else { throw AnalysisJobRunnerError.invalidDrainLimit }
    guard driver == nil else { throw AnalysisJobRunnerError.alreadyProcessing }
    driver = .drain
    stopRequested = false
    defer { driver = nil }

    var outcomes: [AnalysisJobRunnerOutcome] = []
    outcomes.reserveCapacity(min(maximumJobs, 100))
    while outcomes.count < maximumJobs, !stopRequested {
      try Task.checkCancellation()
      let outcome = try await processOneClaimedJob()
      if outcome == .idle { break }
      outcomes.append(outcome)
    }
    return outcomes
  }

  /// Polls indefinitely until `stop()` is called or the calling task is cancelled.
  public func run() async throws {
    guard driver == nil else { throw AnalysisJobRunnerError.alreadyProcessing }
    driver = .polling
    stopRequested = false
    defer {
      activeSleepTask?.cancel()
      activeSleepTask = nil
      driver = nil
    }

    while !stopRequested {
      try Task.checkCancellation()
      let outcome = try await processOneClaimedJob()
      guard outcome == .idle else { continue }
      if stopRequested { return }

      do {
        try await pollSleep()
      } catch is CancellationError {
        if stopRequested { return }
        throw CancellationError()
      }
    }
  }

  /// Stops polling and releases an in-flight claim without consuming an attempt.
  public func stop() {
    stopRequested = true
    activeProviderTask?.cancel()
    activeSleepTask?.cancel()
  }

  /// Cancels a durable job. If it is currently executing, its provider call is
  /// cancelled as well. This is distinct from `stop()`, which requeues the job.
  @discardableResult
  public func cancel(jobID: String) async throws -> AIAnalysisJob {
    let normalizedID = jobID.trimmingCharacters(in: .whitespacesAndNewlines)
    cancellationRequestedJobIDs.insert(normalizedID)
    defer { cancellationRequestedJobIDs.remove(normalizedID) }
    if activeJobID == normalizedID {
      activeProviderTask?.cancel()
    }
    return try await workspaceStore.cancel(jobID: jobID, now: await clock.now())
  }

  private func processOneClaimedJob() async throws -> AnalysisJobRunnerOutcome {
    guard !stopRequested else { return .idle }
    let claimedAt = await clock.now()
    guard let job = try await workspaceStore.claimNextRunnableJob(now: claimedAt) else {
      return .idle
    }
    activeJobID = job.jobID
    defer {
      activeProviderTask?.cancel()
      activeProviderTask = nil
      activeJobID = nil
    }

    do {
      try ensureExecutionMayContinue(jobID: job.jobID)
      let request = try await makeRequest(for: job)
      try ensureExecutionMayContinue(jobID: job.jobID)
      let provider = try await makeProvider(for: job)
      try ensureExecutionMayContinue(jobID: job.jobID)
      if let changed = try await outcomeForChangedState(jobID: job.jobID) {
        activeJobID = nil
        return changed
      }
      try ensureExecutionMayContinue(jobID: job.jobID)

      let providerTask = Task { try await provider.analyze(request) }
      activeProviderTask = providerTask
      let result: AIAnalysisResult
      do {
        result = try await withTaskCancellationHandler(
          operation: { try await providerTask.value },
          onCancel: { providerTask.cancel() }
        )
      } catch {
        let cancellationWasRequested = providerTask.isCancelled
          || stopRequested
          || Task.isCancelled
          || cancellationRequestedJobIDs.contains(job.jobID)
        activeProviderTask = nil
        if cancellationWasRequested {
          let outcome = try await releaseClaimAfterCancellation(job)
          activeJobID = nil
          if Task.isCancelled { throw CancellationError() }
          return outcome
        }
        if error is CancellationError {
          return try await fail(
            job,
            code: .providerCancelledUnexpectedly
          )
        }
        if let providerError = error as? AIProviderError {
          return try await handle(providerError, for: job)
        }
        return try await fail(job, code: .providerUnclassifiedFailure)
      }
      activeProviderTask = nil

      try ensureExecutionMayContinue(jobID: job.jobID)
      guard result.requestID == request.requestID,
            result.schemaVersion == AIAnalysisResult.currentSchemaVersion,
            !result.analysisID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            result.analysisID == result.analysisID.trimmingCharacters(
              in: .whitespacesAndNewlines
            ),
            result.provenance.providerConfigurationID == job.providerID,
            result.provenance.providerKind == provider.configuration.kind,
            result.provenance.model == provider.configuration.model,
            result.provenance.requestSchemaVersion == request.schemaVersion,
            result.provenance.resultSchemaVersion == result.schemaVersion,
            result.provenance.sourceMessageIDs == request.messages.map(\.messageID),
            Self.hasValidCitations(result, request: request) else {
        return try await fail(job, code: .resultContractMismatch)
      }

      let completedAt = await clock.now()
      try ensureExecutionMayContinue(jobID: job.jobID)
      do {
        _ = try await workspaceStore.complete(
          jobID: job.jobID,
          result: result,
          now: completedAt
        )
      } catch {
        if let changed = try await outcomeForChangedState(jobID: job.jobID) {
          activeJobID = nil
          return changed
        }
        if Self.isResultContractFailure(error) {
          return try await fail(job, code: .resultContractMismatch)
        }
        // A result was received and may have been persisted transactionally. Do
        // not overwrite that uncertainty with a misleading provider failure.
        activeJobID = nil
        throw error
      }
      activeJobID = nil
      return .succeeded(jobID: job.jobID, analysisID: result.analysisID)
    } catch ControlSignal.jobCancellationRequested {
      let outcome = try await releaseClaimAfterCancellation(job)
      activeJobID = nil
      return outcome
    } catch is CancellationError {
      activeProviderTask?.cancel()
      activeProviderTask = nil
      let outcome = try await releaseClaimAfterCancellation(job)
      activeJobID = nil
      if Task.isCancelled { throw CancellationError() }
      return outcome
    } catch let PreparationFailure.permanent(code) {
      return try await fail(job, code: code)
    } catch let PreparationFailure.retryable(code) {
      return try await scheduleRetry(job, code: code, retryAfterSeconds: nil)
    } catch let providerError as AIProviderError {
      return try await handle(providerError, for: job)
    } catch {
      // At this point expected provider/preparation failures have already been
      // classified. Preserve a claimed job if durable state itself is unavailable.
      await bestEffortReleaseAfterInfrastructureFailure(job)
      activeJobID = nil
      throw AnalysisJobRunnerError.durableStateUnavailable
    }
  }

  private func makeRequest(for job: AIAnalysisJob) async throws -> AIAnalysisRequest {
    guard job.promptVersion == Self.supportedPromptVersion else {
      throw PreparationFailure.permanent(.unsupportedPromptVersion)
    }
    let range: FrozenMessageRange
    let storedMessages: [StoredMessage]
    do {
      guard let loadedRange = try await messageStore.frozenRange(id: job.frozenRangeID) else {
        throw PreparationFailure.permanent(.frozenRangeNotFound)
      }
      guard loadedRange.eventIDs.count <= AIAnalysisRequest.maximumMessageCount else {
        throw PreparationFailure.permanent(.frozenRangeTooManyMessages)
      }
      range = loadedRange
      storedMessages = try await messageStore.messages(inFrozenRange: range.id)
    } catch let failure as PreparationFailure {
      throw failure
    } catch MessageStoreError.frozenRangeNotFound {
      throw PreparationFailure.permanent(.frozenRangeNotFound)
    } catch {
      throw PreparationFailure.retryable(.frozenRangeReadFailed)
    }

    guard !storedMessages.isEmpty else {
      throw PreparationFailure.permanent(.frozenRangeEmpty)
    }
    guard let rangeStart = range.earliestObservedAt,
          let rangeEnd = range.latestObservedAt else {
      throw PreparationFailure.permanent(.frozenRangeMissingBounds)
    }
    guard range.eventIDs == storedMessages.map({ $0.event.eventID }) else {
      throw PreparationFailure.permanent(.frozenRangeMembershipMismatch)
    }

    let request = AIAnalysisRequest(
      requestID: job.jobID,
      createdAt: job.createdAt,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      mode: job.mode,
      localeIdentifier: configuration.localeIdentifier,
      customInstructions: job.customInstructions,
      messages: storedMessages.map { AIAnalysisSourceMessage(event: $0.event) }
    )
    do {
      try request.validate()
      try Self.validatePromptSize(request)
    } catch AIProviderError.requestTooLarge {
      throw PreparationFailure.permanent(.promptTooLarge)
    } catch {
      throw PreparationFailure.permanent(.analysisRequestInvalid)
    }
    return request
  }

  private func makeProvider(for job: AIAnalysisJob) async throws
    -> any AIAnalysisProviding
  {
    let providerConfiguration: AIProviderConfiguration
    do {
      guard let configuration = try await workspaceStore.providerConfiguration(id: job.providerID)
      else {
        throw PreparationFailure.permanent(.providerConfigurationNotFound)
      }
      providerConfiguration = configuration
    } catch let failure as PreparationFailure {
      throw failure
    } catch WorkspaceStoreError.providerConfigurationDecodingFailed {
      throw PreparationFailure.permanent(.providerConfigurationReadFailed)
    } catch {
      throw PreparationFailure.retryable(.providerConfigurationReadFailed)
    }

    do {
      return try providerFactory.makeProvider(configuration: providerConfiguration)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as AIProviderError {
      throw error
    } catch {
      throw PreparationFailure.permanent(.providerFactoryFailed)
    }
  }

  private func handle(
    _ error: AIProviderError,
    for job: AIAnalysisJob
  ) async throws -> AnalysisJobRunnerOutcome {
    activeProviderTask = nil
    if let controlOutcome = try await controlOutcomeIfRequested(for: job) {
      activeJobID = nil
      return controlOutcome
    }
    if let changed = try await outcomeForChangedState(jobID: job.jobID) {
      activeJobID = nil
      return changed
    }
    if let controlOutcome = try await controlOutcomeIfRequested(for: job) {
      activeJobID = nil
      return controlOutcome
    }

    let code = Self.failureCode(for: error)
    switch error.retryDisposition {
    case .doNotRetry:
      return try await fail(job, code: code)
    case .retry(let retryAfterSeconds):
      return try await scheduleRetry(
        job,
        code: code,
        retryAfterSeconds: retryAfterSeconds
      )
    }
  }

  private func scheduleRetry(
    _ job: AIAnalysisJob,
    code: AnalysisJobFailureCode,
    retryAfterSeconds: TimeInterval?
  ) async throws -> AnalysisJobRunnerOutcome {
    if let controlOutcome = try await controlOutcomeIfRequested(for: job) {
      return controlOutcome
    }
    if let changed = try await outcomeForChangedState(jobID: job.jobID) {
      return changed
    }
    let now = await clock.now()
    if let controlOutcome = try await controlOutcomeIfRequested(for: job) {
      return controlOutcome
    }

    let delay: TimeInterval
    if let retryAfterSeconds,
       retryAfterSeconds.isFinite,
       retryAfterSeconds >= 0 {
      delay = min(configuration.retryMaximumDelaySeconds, retryAfterSeconds)
    } else {
      delay = await exponentialBackoffDelay(attempt: job.attempt)
    }
    if let controlOutcome = try await controlOutcomeIfRequested(for: job) {
      return controlOutcome
    }

    let nextAttemptAt = now.addingTimeInterval(delay)
    let updated: AIAnalysisJob
    do {
      updated = try await workspaceStore.reschedule(
        jobID: job.jobID,
        nextAttemptAt: nextAttemptAt,
        error: code.rawValue,
        now: now
      )
    } catch {
      if let changed = try await outcomeForChangedState(jobID: job.jobID) {
        return changed
      }
      throw error
    }
    if updated.state == .failed {
      return .failed(jobID: job.jobID, errorCode: code)
    }
    return .retryScheduled(
      jobID: job.jobID,
      nextAttemptAt: nextAttemptAt,
      errorCode: code
    )
  }

  private func fail(
    _ job: AIAnalysisJob,
    code: AnalysisJobFailureCode
  ) async throws -> AnalysisJobRunnerOutcome {
    activeProviderTask = nil
    if let controlOutcome = try await controlOutcomeIfRequested(for: job) {
      activeJobID = nil
      return controlOutcome
    }
    if let changed = try await outcomeForChangedState(jobID: job.jobID) {
      activeJobID = nil
      return changed
    }
    let now = await clock.now()
    if let controlOutcome = try await controlOutcomeIfRequested(for: job) {
      activeJobID = nil
      return controlOutcome
    }
    do {
      _ = try await workspaceStore.fail(
        jobID: job.jobID,
        error: code.rawValue,
        now: now
      )
    } catch {
      if let changed = try await outcomeForChangedState(jobID: job.jobID) {
        return changed
      }
      throw error
    }
    activeJobID = nil
    return .failed(jobID: job.jobID, errorCode: code)
  }

  private func controlOutcomeIfRequested(
    for job: AIAnalysisJob
  ) async throws -> AnalysisJobRunnerOutcome? {
    guard stopRequested
      || Task.isCancelled
      || cancellationRequestedJobIDs.contains(job.jobID) else {
      return nil
    }
    let outcome = try await releaseClaimAfterCancellation(job)
    if Task.isCancelled { throw CancellationError() }
    return outcome
  }

  private func releaseClaimAfterCancellation(
    _ job: AIAnalysisJob
  ) async throws -> AnalysisJobRunnerOutcome {
    if cancellationRequestedJobIDs.contains(job.jobID) {
      _ = try await workspaceStore.cancel(jobID: job.jobID, now: await clock.now())
      return .cancelled(jobID: job.jobID)
    }
    if let changed = try await outcomeForChangedState(jobID: job.jobID) {
      return changed
    }
    let now = await clock.now()
    do {
      _ = try await workspaceStore.releaseRunningJob(
        jobID: job.jobID,
        nextAttemptAt: now,
        error: AnalysisJobFailureCode.runnerStopped.rawValue,
        now: now
      )
      return .released(jobID: job.jobID)
    } catch {
      if let changed = try await outcomeForChangedState(jobID: job.jobID) {
        return changed
      }
      throw error
    }
  }

  private func bestEffortReleaseAfterInfrastructureFailure(_ job: AIAnalysisJob) async {
    guard let current = try? await workspaceStore.analysisJob(id: job.jobID),
          current.state == .running else {
      return
    }
    let now = await clock.now()
    _ = try? await workspaceStore.releaseRunningJob(
      jobID: job.jobID,
      nextAttemptAt: now,
      error: AnalysisJobFailureCode.runnerInfrastructureFailure.rawValue,
      now: now
    )
  }

  /// Returns an outcome only if another owner moved the claimed job out of running.
  private func outcomeForChangedState(jobID: String) async throws
    -> AnalysisJobRunnerOutcome?
  {
    guard let current = try await workspaceStore.analysisJob(id: jobID) else {
      return nil
    }
    switch current.state {
    case .running:
      return nil
    case .cancelled:
      return .cancelled(jobID: jobID)
    case .succeeded:
      if let stored = try await workspaceStore.analysisResult(forJobID: jobID) {
        return .succeeded(jobID: jobID, analysisID: stored.result.analysisID)
      }
      return nil
    case .failed:
      let code = current.lastError.flatMap(AnalysisJobFailureCode.init(rawValue:))
        ?? .providerUnclassifiedFailure
      return .failed(jobID: jobID, errorCode: code)
    case .pending, .retryWait:
      return .released(jobID: jobID)
    }
  }

  private func exponentialBackoffDelay(attempt: Int) async -> TimeInterval {
    let exponent = max(0, min(attempt - 1, 62))
    let exponential = configuration.retryBaseDelaySeconds * pow(2, Double(exponent))
    let bounded = min(configuration.retryMaximumDelaySeconds, exponential)
    let random = min(1, max(0, await clock.randomUnitInterval()))
    let multiplier = 1 + configuration.retryJitterFraction * ((2 * random) - 1)
    return min(configuration.retryMaximumDelaySeconds, max(0, bounded * multiplier))
  }

  private func pollSleep() async throws {
    let seconds = configuration.pollIntervalSeconds
    let clock = clock
    let sleepTask = Task { try await clock.sleep(for: seconds) }
    activeSleepTask = sleepTask
    defer { activeSleepTask = nil }
    try await withTaskCancellationHandler(
      operation: { try await sleepTask.value },
      onCancel: { sleepTask.cancel() }
    )
  }

  private func ensureExecutionMayContinue(jobID: String) throws {
    if cancellationRequestedJobIDs.contains(jobID) {
      throw ControlSignal.jobCancellationRequested
    }
    if stopRequested { throw CancellationError() }
    try Task.checkCancellation()
  }

  private static func failureCode(for error: AIProviderError) -> AnalysisJobFailureCode {
    switch error {
    case .invalidConfiguration:
      return .providerInvalidConfiguration
    case .invalidRequest:
      return .analysisRequestInvalid
    case .credentialUnavailable:
      return .providerCredentialUnavailable
    case .requestEncodingFailed:
      return .requestEncodingFailed
    case .requestTooLarge:
      return .promptTooLarge
    case let .transport(transportError):
      return transportError.isRetryable ? .transportRetryable : .transportNotRetryable
    case let .http(_, _, _, isRetryable):
      return isRetryable ? .httpRetryable : .httpNotRetryable
    case .responseTooLarge:
      return .responseTooLarge
    case .responseDecodingFailed:
      return .responseDecodingFailed
    case .emptyResponse:
      return .emptyResponse
    case .modelRefused:
      return .modelRefused
    case .outputIncomplete:
      return .outputIncomplete
    }
  }

  private static func hasValidCitations(
    _ result: AIAnalysisResult,
    request: AIAnalysisRequest
  ) -> Bool {
    let knownIDs = Set(request.messages.map(\.messageID))
    func referencesAreValid(_ references: [String]) -> Bool {
      var seen = Set<String>()
      return references.allSatisfy { knownIDs.contains($0) && seen.insert($0).inserted }
    }

    guard referencesAreValid(result.summarySourceMessageIDs),
          result.topics.allSatisfy({ referencesAreValid($0.sourceMessageIDs) }),
          result.findings.allSatisfy({ referencesAreValid($0.sourceMessageIDs) }),
          result.cryptoAddresses.allSatisfy({ referencesAreValid($0.sourceMessageIDs) }) else {
      return false
    }
    return true
  }

  private static func isResultContractFailure(_ error: Error) -> Bool {
    guard let error = error as? WorkspaceStoreError else { return false }
    switch error {
    case .invalidArgument,
         .analysisResultEncodingFailed,
         .analysisResultJobMismatch,
         .analysisResultProviderMismatch:
      return true
    default:
      return false
    }
  }

  private static func validatePromptSize(_ request: AIAnalysisRequest) throws {
    let input = AnalysisPromptPreflightPayload(request: request)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data: Data
    do {
      data = try encoder.encode(input)
    } catch {
      throw AIProviderError.requestEncodingFailed
    }
    guard data.count <= Self.maximumPromptBytes else {
      throw AIProviderError.requestTooLarge(
        limitBytes: Self.maximumPromptBytes
      )
    }
  }
}

private struct AnalysisPromptPreflightPayload: Encodable {
  let requestID: String
  let mode: AIAnalysisMode
  let rangeStart: Date
  let rangeEnd: Date
  let customInstructions: String?
  let localeIdentifier: String
  let messages: [AIAnalysisSourceMessage]
  let cryptoAddressEvidence: [CryptoAddressEvidence]

  init(request: AIAnalysisRequest) {
    requestID = request.requestID
    mode = request.mode
    rangeStart = request.rangeStart
    rangeEnd = request.rangeEnd
    customInstructions = request.customInstructions
    localeIdentifier = request.localeIdentifier
    messages = request.messages
    cryptoAddressEvidence = CryptoAddressDetector.detect(in: request.messages)
  }

  private enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case mode
    case rangeStart = "range_start"
    case rangeEnd = "range_end"
    case customInstructions = "analysis_instructions"
    case localeIdentifier = "locale_identifier"
    case messages
    case cryptoAddressEvidence = "crypto_address_evidence"
  }
}
