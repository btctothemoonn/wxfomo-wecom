import Foundation
import CryptoKit
import Dispatch

public enum RuleCollectionMatchMode: String, Codable, Equatable, Sendable {
  case any
  case all
}

/// Best-effort protection for Foundation's backtracking regex engine.
/// `reportProgress` does not provide a hard timeout; regex evaluation must
/// still run away from the collection and UI threads.
public enum MessageRuleRegularExpressionPolicy {
  public static let maximumPatternUTF8Length = 2_048
  public static let maximumContentUTF8Length = 65_536
  public static let maximumProgressCallbacks = 512
  public static let bestEffortDeadlineNanoseconds: UInt64 = 50_000_000
}

/// A wall-clock window in an explicitly configured time zone, with an
/// inclusive start and exclusive end.
/// Equal start and end values represent a full day. Overnight windows assign
/// the after-midnight portion to the weekday on which the window started.
public struct MessageRuleTimeWindow: Codable, Equatable, Sendable {
  public let startMinuteOfDay: Int
  public let endMinuteOfDay: Int
  /// Gregorian calendar weekday numbers: Sunday is 1 and Saturday is 7.
  /// An empty collection allows every weekday.
  public let weekdays: [Int]
  public let timeZoneIdentifier: String

  public init(
    startMinuteOfDay: Int,
    endMinuteOfDay: Int,
    weekdays: [Int] = [],
    timeZoneIdentifier: String
  ) {
    self.startMinuteOfDay = startMinuteOfDay
    self.endMinuteOfDay = endMinuteOfDay
    self.weekdays = weekdays
    self.timeZoneIdentifier = timeZoneIdentifier
  }
}

/// Categories are ANDed together. Values within groups, senders, messageTypes,
/// and timeWindows are ORed. Keyword and regex collections use their match mode.
public struct MessageRuleCondition: Codable, Equatable, Sendable {
  public let groups: [String]
  /// Matches either senderStableID or senderDisplayName. Configure stable IDs
  /// when they are available; display names can collide or change.
  public let senders: [String]
  public let includeKeywords: [String]
  public let includeKeywordMode: RuleCollectionMatchMode
  public let excludeKeywords: [String]
  public let regularExpressions: [String]
  public let regularExpressionMode: RuleCollectionMatchMode
  public let messageTypes: [MessageKind]
  public let timeWindows: [MessageRuleTimeWindow]
  public let caseSensitive: Bool

  public init(
    groups: [String] = [],
    senders: [String] = [],
    includeKeywords: [String] = [],
    includeKeywordMode: RuleCollectionMatchMode = .any,
    excludeKeywords: [String] = [],
    regularExpressions: [String] = [],
    regularExpressionMode: RuleCollectionMatchMode = .any,
    messageTypes: [MessageKind] = [],
    timeWindows: [MessageRuleTimeWindow] = [],
    caseSensitive: Bool = false
  ) {
    self.groups = groups
    self.senders = senders
    self.includeKeywords = includeKeywords
    self.includeKeywordMode = includeKeywordMode
    self.excludeKeywords = excludeKeywords
    self.regularExpressions = regularExpressions
    self.regularExpressionMode = regularExpressionMode
    self.messageTypes = messageTypes
    self.timeWindows = timeWindows
    self.caseSensitive = caseSensitive
  }
}

public enum MessageRuleAlertSeverity: String, Codable, Equatable, Sendable {
  case information
  case warning
  case critical
}

/// Actions are data-only intents. MessageRuleEngine never sends notifications,
/// starts scripts, calls AI providers, or performs any other side effect.
public enum MessageRuleAction: Codable, Equatable, Sendable {
  case addTag(String)
  case suppress
  case capture
  case enqueueSummary(configurationID: String?)
  case localAlert(severity: MessageRuleAlertSeverity, title: String?)
  case invokeScript(scriptID: String, arguments: [String])

  private enum ActionType: String, Codable {
    case addTag = "add_tag"
    case suppress
    case capture
    case enqueueSummary = "enqueue_summary"
    case localAlert = "local_alert"
    case invokeScript = "invoke_script"
  }

  private enum CodingKeys: String, CodingKey {
    case type
    case tag
    case configurationID = "configuration_id"
    case severity
    case title
    case scriptID = "script_id"
    case arguments
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(ActionType.self, forKey: .type) {
    case .addTag:
      self = .addTag(try container.decode(String.self, forKey: .tag))
    case .suppress:
      self = .suppress
    case .capture:
      self = .capture
    case .enqueueSummary:
      self = .enqueueSummary(
        configurationID: try container.decodeIfPresent(String.self, forKey: .configurationID)
      )
    case .localAlert:
      self = .localAlert(
        severity: try container.decode(MessageRuleAlertSeverity.self, forKey: .severity),
        title: try container.decodeIfPresent(String.self, forKey: .title)
      )
    case .invokeScript:
      self = .invokeScript(
        scriptID: try container.decode(String.self, forKey: .scriptID),
        arguments: try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .addTag(tag):
      try container.encode(ActionType.addTag, forKey: .type)
      try container.encode(tag, forKey: .tag)
    case .suppress:
      try container.encode(ActionType.suppress, forKey: .type)
    case .capture:
      try container.encode(ActionType.capture, forKey: .type)
    case let .enqueueSummary(configurationID):
      try container.encode(ActionType.enqueueSummary, forKey: .type)
      try container.encodeIfPresent(configurationID, forKey: .configurationID)
    case let .localAlert(severity, title):
      try container.encode(ActionType.localAlert, forKey: .type)
      try container.encode(severity, forKey: .severity)
      try container.encodeIfPresent(title, forKey: .title)
    case let .invokeScript(scriptID, arguments):
      try container.encode(ActionType.invokeScript, forKey: .type)
      try container.encode(scriptID, forKey: .scriptID)
      try container.encode(arguments, forKey: .arguments)
    }
  }
}

public struct MessageRule: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  /// Incremented whenever a persisted rule's condition or actions change.
  public let revision: Int
  public let id: String
  public let name: String
  public let priority: Int
  public let isEnabled: Bool
  public let condition: MessageRuleCondition
  public let actions: [MessageRuleAction]

  public init(
    schemaVersion: Int = 1,
    revision: Int = 1,
    id: String,
    name: String,
    priority: Int = 0,
    isEnabled: Bool = true,
    condition: MessageRuleCondition,
    actions: [MessageRuleAction]
  ) {
    self.schemaVersion = schemaVersion
    self.revision = revision
    self.id = id
    self.name = name
    self.priority = priority
    self.isEnabled = isEnabled
    self.condition = condition
    self.actions = actions
  }
}

public enum MessageRuleEvaluationStatus: String, Codable, Equatable, Sendable {
  case disabled
  case matched
  case notMatched = "not_matched"
  case invalid
}

public enum MessageRuleReasonOutcome: String, Codable, Equatable, Sendable {
  case satisfied
  case failed
  case invalid
}

public enum MessageRuleReasonCode: String, Codable, Equatable, Sendable {
  case unconditional
  case groupMatched = "group_matched"
  case groupNotMatched = "group_not_matched"
  case senderMatched = "sender_matched"
  case senderNotMatched = "sender_not_matched"
  case includeKeywordMatched = "include_keyword_matched"
  case includeKeywordNotMatched = "include_keyword_not_matched"
  case excludeKeywordClear = "exclude_keyword_clear"
  case excludeKeywordMatched = "exclude_keyword_matched"
  case regularExpressionMatched = "regular_expression_matched"
  case regularExpressionNotMatched = "regular_expression_not_matched"
  case messageTypeMatched = "message_type_matched"
  case messageTypeNotMatched = "message_type_not_matched"
  case timeWindowMatched = "time_window_matched"
  case timeWindowNotMatched = "time_window_not_matched"
  case invalidRegularExpression = "invalid_regular_expression"
  case invalidTimeWindow = "invalid_time_window"
  case invalidTimeZone = "invalid_time_zone"
  case emptyConditionValue = "empty_condition_value"
  case emptyRuleIdentifier = "empty_rule_identifier"
  case duplicateRuleIdentifier = "duplicate_rule_identifier"
  case invalidAction = "invalid_action"
  case unsupportedSchemaVersion = "unsupported_schema_version"
  case invalidRuleRevision = "invalid_rule_revision"
  case regularExpressionWorkLimitExceeded = "regular_expression_work_limit_exceeded"
  case unsafeRegularExpression = "unsafe_regular_expression"
}

public struct MessageRuleReason: Codable, Equatable, Sendable {
  public let code: MessageRuleReasonCode
  public let outcome: MessageRuleReasonOutcome
  /// Constraint values or configuration identifiers, never the message body.
  /// Values may still contain sensitive group/sender names or rule terms and
  /// must be redacted before logging or upload.
  public let values: [String]

  public init(
    code: MessageRuleReasonCode,
    outcome: MessageRuleReasonOutcome,
    values: [String] = []
  ) {
    self.code = code
    self.outcome = outcome
    self.values = values
  }
}

public struct MessageRuleTrace: Codable, Equatable, Sendable {
  public let ruleID: String
  public let ruleName: String
  public let priority: Int
  public let status: MessageRuleEvaluationStatus
  public let reasons: [MessageRuleReason]

  public init(
    ruleID: String,
    ruleName: String,
    priority: Int,
    status: MessageRuleEvaluationStatus,
    reasons: [MessageRuleReason]
  ) {
    self.ruleID = ruleID
    self.ruleName = ruleName
    self.priority = priority
    self.status = status
    self.reasons = reasons
  }
}

public struct MessageRuleActionIntent: Codable, Equatable, Sendable {
  public let intentID: String
  public let eventID: String
  public let ruleID: String
  public let ruleName: String
  public let rulePriority: Int
  public let ruleRevision: Int
  public let actionIndex: Int
  public let action: MessageRuleAction

  public init(
    intentID: String,
    eventID: String,
    ruleID: String,
    ruleName: String,
    rulePriority: Int,
    ruleRevision: Int,
    actionIndex: Int,
    action: MessageRuleAction
  ) {
    self.intentID = intentID
    self.eventID = eventID
    self.ruleID = ruleID
    self.ruleName = ruleName
    self.rulePriority = rulePriority
    self.ruleRevision = ruleRevision
    self.actionIndex = actionIndex
    self.action = action
  }
}

public struct MessageRuleEvaluation: Codable, Equatable, Sendable {
  public let eventID: String
  public let traces: [MessageRuleTrace]
  public let actionIntents: [MessageRuleActionIntent]

  public init(
    eventID: String,
    traces: [MessageRuleTrace],
    actionIntents: [MessageRuleActionIntent]
  ) {
    self.eventID = eventID
    self.traces = traces
    self.actionIntents = actionIntents
  }

  public var matchedRuleIDs: [String] {
    traces.filter { $0.status == .matched }.map(\.ruleID)
  }

  /// Suppression affects presentation or downstream forwarding. It is
  /// the effective winner when both suppress and capture intents are present.
  /// All intents and traces remain available for audit.
  public var shouldSuppress: Bool {
    actionIntents.contains { intent in
      if case .suppress = intent.action { return true }
      return false
    }
  }

  public var hasCaptureIntent: Bool {
    actionIntents.contains { intent in
      if case .capture = intent.action { return true }
      return false
    }
  }

  public var shouldCapture: Bool {
    !shouldSuppress && hasCaptureIntent
  }

  public var tags: [String] {
    var seen = Set<String>()
    return actionIntents.compactMap { intent in
      guard case let .addTag(tag) = intent.action, seen.insert(tag).inserted else {
        return nil
      }
      return tag
    }
  }
}

public enum MessageRuleEngine {
  /// Configuration-only validation suitable for a rule editor before save.
  /// Cross-rule duplicate IDs are checked during evaluation.
  public static func validationReasons(for rule: MessageRule) -> [MessageRuleReason] {
    var reasons: [MessageRuleReason] = []
    if rule.schemaVersion != MessageRule.currentSchemaVersion {
      reasons.append(
        MessageRuleReason(
          code: .unsupportedSchemaVersion,
          outcome: .invalid,
          values: [String(rule.schemaVersion)]
        )
      )
    }
    if rule.revision < 1 {
      reasons.append(
        MessageRuleReason(
          code: .invalidRuleRevision,
          outcome: .invalid,
          values: [String(rule.revision)]
        )
      )
    }
    if trimmed(rule.id).isEmpty {
      reasons.append(MessageRuleReason(code: .emptyRuleIdentifier, outcome: .invalid))
    }
    if let invalidActionIndex = firstInvalidActionIndex(in: rule.actions) {
      reasons.append(
        MessageRuleReason(
          code: .invalidAction,
          outcome: .invalid,
          values: [String(invalidActionIndex)]
        )
      )
    }
    reasons.append(contentsOf: conditionConfigurationReasons(rule.condition))
    return reasons
  }

  public static func evaluate(
    _ event: MessageEvent,
    rules: [MessageRule]
  ) -> MessageRuleEvaluation {
    let duplicateIDs = duplicateIdentifiers(rules.map(\.id))
    let orderedRules = rules.enumerated().sorted { lhs, rhs in
      if lhs.element.priority != rhs.element.priority {
        return lhs.element.priority > rhs.element.priority
      }
      if lhs.element.id != rhs.element.id {
        return lhs.element.id < rhs.element.id
      }
      if lhs.element.name != rhs.element.name {
        return lhs.element.name < rhs.element.name
      }
      return lhs.offset < rhs.offset
    }

    var traces: [MessageRuleTrace] = []
    var intents: [MessageRuleActionIntent] = []

    for (_, rule) in orderedRules {
      let trace: MessageRuleTrace
      if !rule.isEnabled {
        trace = MessageRuleTrace(
          ruleID: rule.id,
          ruleName: rule.name,
          priority: rule.priority,
          status: .disabled,
          reasons: []
        )
      } else {
        var configurationReasons = validationReasons(for: rule)
        if duplicateIDs.contains(rule.id) {
          configurationReasons.append(
            MessageRuleReason(
              code: .duplicateRuleIdentifier,
              outcome: .invalid,
              values: [rule.id]
            )
          )
        }
        if configurationReasons.isEmpty {
          let conditionResult = evaluateCondition(
            event,
            condition: rule.condition
          )
          trace = MessageRuleTrace(
            ruleID: rule.id,
            ruleName: rule.name,
            priority: rule.priority,
            status: conditionResult.status,
            reasons: conditionResult.reasons
          )
        } else {
          trace = invalidTrace(rule, reasons: configurationReasons)
        }
      }

      traces.append(trace)
      guard trace.status == .matched else { continue }

      var actionOccurrences: [String: Int] = [:]
      for (actionIndex, action) in rule.actions.enumerated() {
        let actionIdentity = stableActionIdentity(action)
        let occurrence = actionOccurrences[actionIdentity, default: 0]
        actionOccurrences[actionIdentity] = occurrence + 1
        let identity = stableIdentity([
          event.eventID,
          rule.id,
          String(rule.revision),
          actionIdentity,
          String(occurrence),
        ])
        intents.append(
          MessageRuleActionIntent(
            intentID: sha256Hex(identity),
            eventID: event.eventID,
            ruleID: rule.id,
            ruleName: rule.name,
            rulePriority: rule.priority,
            ruleRevision: rule.revision,
            actionIndex: actionIndex,
            action: action
          )
        )
      }
    }

    return MessageRuleEvaluation(
      eventID: event.eventID,
      traces: traces,
      actionIntents: intents
    )
  }

  fileprivate static func evaluateCondition(
    _ event: MessageEvent,
    condition: MessageRuleCondition
  ) -> ConditionEvaluation {
    var reasons: [MessageRuleReason] = []
    var hasFailure = false
    var hasInvalidConfiguration = false

    func append(_ reason: MessageRuleReason) {
      reasons.append(reason)
      if reason.outcome == .failed { hasFailure = true }
      if reason.outcome == .invalid { hasInvalidConfiguration = true }
    }

    let stringCollections: [(String, [String])] = [
      ("groups", condition.groups),
      ("senders", condition.senders),
      ("include_keywords", condition.includeKeywords),
      ("exclude_keywords", condition.excludeKeywords),
      ("regular_expressions", condition.regularExpressions),
    ]
    let emptyCollections = stringCollections.compactMap { key, values in
      values.contains(where: { trimmed($0).isEmpty }) ? key : nil
    }
    if !emptyCollections.isEmpty {
      append(
        MessageRuleReason(
          code: .emptyConditionValue,
          outcome: .invalid,
          values: emptyCollections.sorted()
        )
      )
    }

    if !condition.groups.isEmpty {
      let matches = condition.groups.filter {
        textEquals(event.group, $0, caseSensitive: condition.caseSensitive)
      }
      append(
        MessageRuleReason(
          code: matches.isEmpty ? .groupNotMatched : .groupMatched,
          outcome: matches.isEmpty ? .failed : .satisfied,
          values: matches
        )
      )
    }

    if !condition.senders.isEmpty {
      let candidates = [event.senderStableID, event.senderDisplayName].compactMap { $0 }
      let matches = condition.senders.filter { allowedSender in
        candidates.contains {
          textEquals($0, allowedSender, caseSensitive: condition.caseSensitive)
        }
      }
      append(
        MessageRuleReason(
          code: matches.isEmpty ? .senderNotMatched : .senderMatched,
          outcome: matches.isEmpty ? .failed : .satisfied,
          values: matches
        )
      )
    }

    if !condition.includeKeywords.isEmpty {
      let matches = matchingKeywords(
        condition.includeKeywords,
        content: event.content,
        caseSensitive: condition.caseSensitive
      )
      let satisfied = collectionMatches(
        matchCount: matches.count,
        itemCount: condition.includeKeywords.count,
        mode: condition.includeKeywordMode
      )
      append(
        MessageRuleReason(
          code: satisfied ? .includeKeywordMatched : .includeKeywordNotMatched,
          outcome: satisfied ? .satisfied : .failed,
          values: matches
        )
      )
    }

    if !condition.excludeKeywords.isEmpty {
      let matches = matchingKeywords(
        condition.excludeKeywords,
        content: event.content,
        caseSensitive: condition.caseSensitive
      )
      append(
        MessageRuleReason(
          code: matches.isEmpty ? .excludeKeywordClear : .excludeKeywordMatched,
          outcome: matches.isEmpty ? .satisfied : .failed,
          values: matches
        )
      )
    }

    if !condition.regularExpressions.isEmpty {
      let regularExpressionResult = evaluateRegularExpressions(
        condition.regularExpressions,
        content: event.content,
        mode: condition.regularExpressionMode,
        caseSensitive: condition.caseSensitive
      )
      for invalidPattern in regularExpressionResult.invalidPatterns {
        append(
          MessageRuleReason(
            code: .invalidRegularExpression,
            outcome: .invalid,
            values: [invalidPattern]
          )
        )
      }
      for unsafePattern in regularExpressionResult.unsafePatterns {
        append(
          MessageRuleReason(
            code: .unsafeRegularExpression,
            outcome: .invalid,
            values: [unsafePattern]
          )
        )
      }
      for limitedPattern in regularExpressionResult.workLimitedPatterns {
        append(
          MessageRuleReason(
            code: .regularExpressionWorkLimitExceeded,
            outcome: .invalid,
            values: [limitedPattern]
          )
        )
      }
      if regularExpressionResult.invalidPatterns.isEmpty,
         regularExpressionResult.unsafePatterns.isEmpty,
         regularExpressionResult.workLimitedPatterns.isEmpty
      {
        append(
          MessageRuleReason(
            code: regularExpressionResult.satisfied
              ? .regularExpressionMatched
              : .regularExpressionNotMatched,
            outcome: regularExpressionResult.satisfied ? .satisfied : .failed,
            values: regularExpressionResult.matchedPatterns
          )
        )
      }
    }

    if !condition.messageTypes.isEmpty {
      let matches = condition.messageTypes.filter { $0 == event.messageType }
      append(
        MessageRuleReason(
          code: matches.isEmpty ? .messageTypeNotMatched : .messageTypeMatched,
          outcome: matches.isEmpty ? .failed : .satisfied,
          values: matches.map(\.rawValue)
        )
      )
    }

    if !condition.timeWindows.isEmpty {
      let results = condition.timeWindows.enumerated().map { index, window in
        evaluateTimeWindow(
          window,
          at: event.observedAt,
          index: index
        )
      }
      let invalidResults = results.filter { $0.outcome == .invalid }
      if !invalidResults.isEmpty {
        invalidResults.forEach(append)
      } else {
        let matches = results.filter { $0.outcome == .satisfied }
        append(
          MessageRuleReason(
            code: matches.isEmpty ? .timeWindowNotMatched : .timeWindowMatched,
            outcome: matches.isEmpty ? .failed : .satisfied,
            values: matches.flatMap(\.values)
          )
        )
      }
    }

    if reasons.isEmpty {
      reasons.append(
        MessageRuleReason(code: .unconditional, outcome: .satisfied)
      )
    }

    let status: MessageRuleEvaluationStatus
    if hasInvalidConfiguration {
      status = .invalid
    } else if hasFailure {
      status = .notMatched
    } else {
      status = .matched
    }
    return ConditionEvaluation(status: status, reasons: reasons)
  }

  private static func invalidTrace(
    _ rule: MessageRule,
    reasons: [MessageRuleReason]
  ) -> MessageRuleTrace {
    MessageRuleTrace(
      ruleID: rule.id,
      ruleName: rule.name,
      priority: rule.priority,
      status: .invalid,
      reasons: reasons
    )
  }

  private static func firstInvalidActionIndex(in actions: [MessageRuleAction]) -> Int? {
    for (index, action) in actions.enumerated() {
      switch action {
      case let .addTag(tag) where trimmed(tag).isEmpty:
        return index
      case let .enqueueSummary(configurationID?) where trimmed(configurationID).isEmpty:
        return index
      case let .invokeScript(scriptID, _) where trimmed(scriptID).isEmpty:
        return index
      default:
        continue
      }
    }
    return nil
  }

  private static func duplicateIdentifiers(_ identifiers: [String]) -> Set<String> {
    var seen = Set<String>()
    var duplicates = Set<String>()
    for identifier in identifiers where !seen.insert(identifier).inserted {
      duplicates.insert(identifier)
    }
    return duplicates
  }
}

private func conditionConfigurationReasons(
  _ condition: MessageRuleCondition
) -> [MessageRuleReason] {
  var reasons: [MessageRuleReason] = []
  let stringCollections: [(String, [String])] = [
    ("groups", condition.groups),
    ("senders", condition.senders),
    ("include_keywords", condition.includeKeywords),
    ("exclude_keywords", condition.excludeKeywords),
    ("regular_expressions", condition.regularExpressions),
  ]
  let emptyCollections = stringCollections.compactMap { key, values in
    values.contains(where: { trimmed($0).isEmpty }) ? key : nil
  }
  if !emptyCollections.isEmpty {
    reasons.append(
      MessageRuleReason(
        code: .emptyConditionValue,
        outcome: .invalid,
        values: emptyCollections.sorted()
      )
    )
  }

  let regexOptions: NSRegularExpression.Options = condition.caseSensitive
    ? []
    : [.caseInsensitive]
  for pattern in condition.regularExpressions where !trimmed(pattern).isEmpty {
    if pattern.utf8.count > MessageRuleRegularExpressionPolicy.maximumPatternUTF8Length {
      reasons.append(
        MessageRuleReason(
          code: .regularExpressionWorkLimitExceeded,
          outcome: .invalid,
          values: [pattern]
        )
      )
    } else if hasLikelyCatastrophicRegularExpressionStructure(pattern) {
      reasons.append(
        MessageRuleReason(
          code: .unsafeRegularExpression,
          outcome: .invalid,
          values: [pattern]
        )
      )
    } else {
      do {
        _ = try NSRegularExpression(pattern: pattern, options: regexOptions)
      } catch {
        reasons.append(
          MessageRuleReason(
            code: .invalidRegularExpression,
            outcome: .invalid,
            values: [pattern]
          )
        )
      }
    }
  }

  for (index, window) in condition.timeWindows.enumerated() {
    if !(0...1_439).contains(window.startMinuteOfDay)
      || !(0...1_439).contains(window.endMinuteOfDay)
      || !window.weekdays.allSatisfy({ (1...7).contains($0) })
    {
      reasons.append(
        MessageRuleReason(
          code: .invalidTimeWindow,
          outcome: .invalid,
          values: [String(index)]
        )
      )
    } else if TimeZone(identifier: window.timeZoneIdentifier) == nil {
      reasons.append(
        MessageRuleReason(
          code: .invalidTimeZone,
          outcome: .invalid,
          values: [String(index), window.timeZoneIdentifier]
        )
      )
    }
  }
  return reasons
}

private struct ConditionEvaluation {
  let status: MessageRuleEvaluationStatus
  let reasons: [MessageRuleReason]
}

private struct RegularExpressionEvaluation {
  let satisfied: Bool
  let matchedPatterns: [String]
  let invalidPatterns: [String]
  let unsafePatterns: [String]
  let workLimitedPatterns: [String]
}

private struct RegularExpressionMatchAttempt {
  let matched: Bool
  let workLimitExceeded: Bool
}

private func evaluateRegularExpressions(
  _ patterns: [String],
  content: String,
  mode: RuleCollectionMatchMode,
  caseSensitive: Bool
) -> RegularExpressionEvaluation {
  let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
  let contentRange = NSRange(content.startIndex..<content.endIndex, in: content)
  var matches: [String] = []
  var invalidPatterns: [String] = []
  var unsafePatterns: [String] = []
  var workLimitedPatterns: [String] = []

  guard content.utf8.count
    <= MessageRuleRegularExpressionPolicy.maximumContentUTF8Length
  else {
    return RegularExpressionEvaluation(
      satisfied: false,
      matchedPatterns: [],
      invalidPatterns: [],
      unsafePatterns: [],
      workLimitedPatterns: patterns
    )
  }

  for pattern in patterns {
    guard pattern.utf8.count
      <= MessageRuleRegularExpressionPolicy.maximumPatternUTF8Length
    else {
      workLimitedPatterns.append(pattern)
      continue
    }
    guard !hasLikelyCatastrophicRegularExpressionStructure(pattern) else {
      unsafePatterns.append(pattern)
      continue
    }
    do {
      let expression = try NSRegularExpression(pattern: pattern, options: options)
      let attempt = bestEffortRegularExpressionMatch(
        expression,
        content: content,
        range: contentRange
      )
      if attempt.workLimitExceeded {
        workLimitedPatterns.append(pattern)
      } else if attempt.matched {
        matches.append(pattern)
      }
    } catch {
      invalidPatterns.append(pattern)
    }
  }

  return RegularExpressionEvaluation(
    satisfied: invalidPatterns.isEmpty
      && unsafePatterns.isEmpty
      && workLimitedPatterns.isEmpty
      && collectionMatches(
      matchCount: matches.count,
      itemCount: patterns.count,
      mode: mode
    ),
    matchedPatterns: matches,
    invalidPatterns: invalidPatterns,
    unsafePatterns: unsafePatterns,
    workLimitedPatterns: workLimitedPatterns
  )
}

private func bestEffortRegularExpressionMatch(
  _ expression: NSRegularExpression,
  content: String,
  range: NSRange
) -> RegularExpressionMatchAttempt {
  let startedAt = DispatchTime.now().uptimeNanoseconds
  var progressCallbacks = 0
  var matched = false
  var workLimitExceeded = false

  expression.enumerateMatches(
    in: content,
    options: [.reportProgress],
    range: range
  ) { result, flags, stop in
    if result != nil {
      matched = true
      stop.pointee = true
      return
    }
    guard flags.contains(.progress) else { return }
    progressCallbacks += 1
    let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
    if progressCallbacks
      >= MessageRuleRegularExpressionPolicy.maximumProgressCallbacks
      || elapsed
        >= MessageRuleRegularExpressionPolicy.bestEffortDeadlineNanoseconds
    {
      workLimitExceeded = true
      stop.pointee = true
    }
  }

  return RegularExpressionMatchAttempt(
    matched: matched,
    workLimitExceeded: workLimitExceeded
  )
}

private struct RegularExpressionGroupState {
  var containsQuantifier = false
  var containsAlternation = false
}

/// Rejects common exponential-backtracking shapes such as `(a+)+`,
/// `(a|aa)+`, nested quantified groups, and numeric backreferences.
private func hasLikelyCatastrophicRegularExpressionStructure(_ pattern: String) -> Bool {
  let characters = Array(pattern)
  var groups = [RegularExpressionGroupState()]
  var inCharacterClass = false
  var index = 0

  while index < characters.count {
    let character = characters[index]
    if character == "\\" {
      if index + 1 < characters.count, characters[index + 1].isNumber {
        return true
      }
      index += 2
      continue
    }
    if character == "[" && !inCharacterClass {
      inCharacterClass = true
      index += 1
      continue
    }
    if character == "]" && inCharacterClass {
      inCharacterClass = false
      index += 1
      continue
    }
    if inCharacterClass {
      index += 1
      continue
    }

    switch character {
    case "(":
      groups.append(RegularExpressionGroupState())
    case "|":
      groups[groups.count - 1].containsAlternation = true
    case "*", "+":
      groups[groups.count - 1].containsQuantifier = true
    case "?":
      if index == 0 || characters[index - 1] != "(" {
        groups[groups.count - 1].containsQuantifier = true
      }
    case "{":
      if regularExpressionBraceIsQuantifier(characters, at: index) {
        groups[groups.count - 1].containsQuantifier = true
      }
    case ")" where groups.count > 1:
      let closed = groups.removeLast()
      let repetition = regularExpressionTokenRepeats(characters, at: index + 1)
      if repetition && (closed.containsQuantifier || closed.containsAlternation) {
        return true
      }
      if closed.containsQuantifier || repetition {
        groups[groups.count - 1].containsQuantifier = true
      }
    default:
      break
    }
    index += 1
  }
  return false
}

private func regularExpressionBraceIsQuantifier(
  _ characters: [Character],
  at index: Int
) -> Bool {
  guard index + 1 < characters.count else { return false }
  var cursor = index + 1
  var sawDigit = false
  while cursor < characters.count, characters[cursor] != "}" {
    let character = characters[cursor]
    guard character.isNumber || character == "," else { return false }
    if character.isNumber { sawDigit = true }
    cursor += 1
  }
  return sawDigit && cursor < characters.count
}

private func regularExpressionTokenRepeats(
  _ characters: [Character],
  at index: Int
) -> Bool {
  guard index < characters.count else { return false }
  if characters[index] == "*" || characters[index] == "+" { return true }
  guard characters[index] == "{",
        regularExpressionBraceIsQuantifier(characters, at: index)
  else {
    return false
  }

  var cursor = index + 1
  var body = ""
  while cursor < characters.count, characters[cursor] != "}" {
    body.append(characters[cursor])
    cursor += 1
  }
  let bounds = body.split(separator: ",", omittingEmptySubsequences: false)
  if bounds.count == 1 {
    return (Int(bounds[0]) ?? 0) > 1
  }
  if bounds.count == 2, bounds[1].isEmpty { return true }
  return bounds.count == 2 && (Int(bounds[1]) ?? 0) > 1
}

private func evaluateTimeWindow(
  _ window: MessageRuleTimeWindow,
  at date: Date,
  index: Int
) -> MessageRuleReason {
  let indexValue = String(index)
  guard (0...1_439).contains(window.startMinuteOfDay),
        (0...1_439).contains(window.endMinuteOfDay),
        window.weekdays.allSatisfy({ (1...7).contains($0) })
  else {
    return MessageRuleReason(
      code: .invalidTimeWindow,
      outcome: .invalid,
      values: [indexValue]
    )
  }

  let timeZoneIdentifier = window.timeZoneIdentifier
  guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
    return MessageRuleReason(
      code: .invalidTimeZone,
      outcome: .invalid,
      values: [indexValue, timeZoneIdentifier]
    )
  }

  var calendar = Calendar(identifier: .gregorian)
  calendar.locale = Locale(identifier: "en_US_POSIX")
  calendar.timeZone = timeZone
  let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
  guard let weekday = components.weekday,
        let hour = components.hour,
        let minute = components.minute
  else {
    return MessageRuleReason(
      code: .invalidTimeWindow,
      outcome: .invalid,
      values: [indexValue]
    )
  }

  let minuteOfDay = hour * 60 + minute
  let isFullDay = window.startMinuteOfDay == window.endMinuteOfDay
  let isOvernight = window.startMinuteOfDay > window.endMinuteOfDay
  let timeMatches: Bool
  if isFullDay {
    timeMatches = true
  } else if isOvernight {
    timeMatches = minuteOfDay >= window.startMinuteOfDay
      || minuteOfDay < window.endMinuteOfDay
  } else {
    timeMatches = minuteOfDay >= window.startMinuteOfDay
      && minuteOfDay < window.endMinuteOfDay
  }

  var effectiveWeekday = weekday
  if isOvernight && minuteOfDay < window.endMinuteOfDay {
    effectiveWeekday = weekday == 1 ? 7 : weekday - 1
  }
  let weekdayMatches = window.weekdays.isEmpty
    || window.weekdays.contains(effectiveWeekday)
  return MessageRuleReason(
    code: timeMatches && weekdayMatches ? .timeWindowMatched : .timeWindowNotMatched,
    outcome: timeMatches && weekdayMatches ? .satisfied : .failed,
    values: timeMatches && weekdayMatches ? [indexValue, timeZoneIdentifier] : []
  )
}

private func matchingKeywords(
  _ keywords: [String],
  content: String,
  caseSensitive: Bool
) -> [String] {
  let comparableContent = normalized(content, caseSensitive: caseSensitive)
  return keywords.filter {
    comparableContent.contains(normalized($0, caseSensitive: caseSensitive))
  }
}

private func collectionMatches(
  matchCount: Int,
  itemCount: Int,
  mode: RuleCollectionMatchMode
) -> Bool {
  switch mode {
  case .any:
    return matchCount > 0
  case .all:
    return matchCount == itemCount
  }
}

private func textEquals(_ lhs: String, _ rhs: String, caseSensitive: Bool) -> Bool {
  normalized(lhs, caseSensitive: caseSensitive)
    == normalized(rhs, caseSensitive: caseSensitive)
}

private func normalized(_ value: String, caseSensitive: Bool) -> String {
  let value = trimmed(value)
  guard !caseSensitive else { return value }
  return value.folding(
    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
    locale: Locale(identifier: "en_US_POSIX")
  )
}

private func trimmed(_ value: String) -> String {
  value.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func stableIdentity(_ components: [String]) -> String {
  components
    .map { "\($0.utf8.count):\($0)" }
    .joined()
}

private func sha256Hex(_ value: String) -> String {
  SHA256.hash(data: Data(value.utf8))
    .map { String(format: "%02x", $0) }
    .joined()
}

private func stableActionIdentity(_ action: MessageRuleAction) -> String {
  switch action {
  case let .addTag(tag):
    return stableIdentity(["add_tag", tag])
  case .suppress:
    return stableIdentity(["suppress"])
  case .capture:
    return stableIdentity(["capture"])
  case let .enqueueSummary(configurationID):
    return stableIdentity([
      "enqueue_summary",
      configurationID == nil ? "nil" : "some",
      configurationID ?? "",
    ])
  case let .localAlert(severity, title):
    return stableIdentity([
      "local_alert",
      severity.rawValue,
      title == nil ? "nil" : "some",
      title ?? "",
    ])
  case let .invokeScript(scriptID, arguments):
    return stableIdentity(["invoke_script", scriptID, String(arguments.count)] + arguments)
  }
}

private struct StableFiniteSum {
  let value: Double
  let overflowed: Bool
}

/// Scales inputs before summing so finite configuration values cannot overflow
/// during accumulation. An unrepresentable final raw value is saturated while
/// the caller records an explicit diagnostic.
private func stableFiniteSum(_ values: [Double]) -> StableFiniteSum {
  let scale = values.reduce(0) { max($0, abs($1)) }
  guard scale > 0 else {
    return StableFiniteSum(value: 0, overflowed: false)
  }

  var scaledSum = 0.0
  var compensation = 0.0
  for value in values {
    let adjusted = value / scale - compensation
    let next = scaledSum + adjusted
    compensation = (next - scaledSum) - adjusted
    scaledSum = next
  }

  let value = scaledSum * scale
  guard value.isFinite else {
    return StableFiniteSum(
      value: scaledSum.sign == .minus
        ? -Double.greatestFiniteMagnitude
        : Double.greatestFiniteMagnitude,
      overflowed: true
    )
  }
  return StableFiniteSum(value: value, overflowed: false)
}

public enum MessageQuantificationDimension: String, Codable, CaseIterable, Equatable, Sendable {
  case relevance
  case urgency
  case actionability
  case novelty
  case sourceWeight = "source_weight"
}

public enum MessageQuantificationSource: String, Codable, Equatable, Sendable {
  case ruleBased = "rule_based"
}

public enum MessageQuantificationLimitation: String, Codable, Equatable, Sendable {
  case capturedEventOnly = "captured_event_only"
  case collectionCompletenessNotMeasured = "collection_completeness_not_measured"
  case semanticMeaningDependsOnConfiguredRules = "semantic_meaning_depends_on_configured_rules"
}

public struct MessageDimensionValues: Codable, Equatable, Sendable {
  public let relevance: Double
  public let urgency: Double
  public let actionability: Double
  public let novelty: Double
  public let sourceWeight: Double

  public init(
    relevance: Double,
    urgency: Double,
    actionability: Double,
    novelty: Double,
    sourceWeight: Double
  ) {
    self.relevance = relevance
    self.urgency = urgency
    self.actionability = actionability
    self.novelty = novelty
    self.sourceWeight = sourceWeight
  }

  public static let zero = MessageDimensionValues(
    relevance: 0,
    urgency: 0,
    actionability: 0,
    novelty: 0,
    sourceWeight: 0
  )

  public static let equalWeights = MessageDimensionValues(
    relevance: 1,
    urgency: 1,
    actionability: 1,
    novelty: 1,
    sourceWeight: 1
  )

  public func value(for dimension: MessageQuantificationDimension) -> Double {
    switch dimension {
    case .relevance: relevance
    case .urgency: urgency
    case .actionability: actionability
    case .novelty: novelty
    case .sourceWeight: sourceWeight
    }
  }
}

public struct MessageScoreFeature: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let id: String
  public let name: String
  public let priority: Int
  public let isEnabled: Bool
  public let dimension: MessageQuantificationDimension
  /// Additive points. Negative values are allowed; final dimensions are clamped to 0...100.
  public let points: Double
  public let condition: MessageRuleCondition

  public init(
    schemaVersion: Int = 1,
    id: String,
    name: String,
    priority: Int = 0,
    isEnabled: Bool = true,
    dimension: MessageQuantificationDimension,
    points: Double,
    condition: MessageRuleCondition
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.name = name
    self.priority = priority
    self.isEnabled = isEnabled
    self.dimension = dimension
    self.points = points
    self.condition = condition
  }
}

public struct MessageQuantificationConfiguration: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let baselines: MessageDimensionValues
  public let weights: MessageDimensionValues
  public let features: [MessageScoreFeature]

  public init(
    schemaVersion: Int = 1,
    baselines: MessageDimensionValues = .zero,
    weights: MessageDimensionValues = .equalWeights,
    features: [MessageScoreFeature] = []
  ) {
    self.schemaVersion = schemaVersion
    self.baselines = baselines
    self.weights = weights
    self.features = features
  }
}

public enum MessageScoreFeatureStatus: String, Codable, Equatable, Sendable {
  case disabled
  case applied
  case notMatched = "not_matched"
  case invalid
}

public struct MessageScoreFeatureEvaluation: Codable, Equatable, Sendable {
  public let featureID: String
  public let featureName: String
  public let priority: Int
  public let dimension: MessageQuantificationDimension
  public let configuredPoints: Double
  public let status: MessageScoreFeatureStatus
  public let reasons: [MessageRuleReason]

  public init(
    featureID: String,
    featureName: String,
    priority: Int,
    dimension: MessageQuantificationDimension,
    configuredPoints: Double,
    status: MessageScoreFeatureStatus,
    reasons: [MessageRuleReason]
  ) {
    self.featureID = featureID
    self.featureName = featureName
    self.priority = priority
    self.dimension = dimension
    self.configuredPoints = configuredPoints
    self.status = status
    self.reasons = reasons
  }
}

public struct MessageDimensionScore: Codable, Equatable, Sendable {
  public let dimension: MessageQuantificationDimension
  public let baseline: Double
  public let rawScore: Double
  public let score: Double
  public let configuredWeight: Double
  public let normalizedWeight: Double
  public let weightedContribution: Double
  public let appliedFeatureIDs: [String]

  public init(
    dimension: MessageQuantificationDimension,
    baseline: Double,
    rawScore: Double,
    score: Double,
    configuredWeight: Double,
    normalizedWeight: Double,
    weightedContribution: Double,
    appliedFeatureIDs: [String]
  ) {
    self.dimension = dimension
    self.baseline = baseline
    self.rawScore = rawScore
    self.score = score
    self.configuredWeight = configuredWeight
    self.normalizedWeight = normalizedWeight
    self.weightedContribution = weightedContribution
    self.appliedFeatureIDs = appliedFeatureIDs
  }
}

public enum MessageQuantificationDiagnosticCode: String, Codable, Equatable, Sendable {
  case unsupportedSchemaVersion = "unsupported_schema_version"
  case emptyFeatureIdentifier = "empty_feature_identifier"
  case duplicateFeatureIdentifier = "duplicate_feature_identifier"
  case invalidFeaturePoints = "invalid_feature_points"
  case invalidBaseline = "invalid_baseline"
  case invalidWeight = "invalid_weight"
  case zeroWeightSum = "zero_weight_sum"
  case scoreOverflow = "score_overflow"
}

public struct MessageQuantificationDiagnostic: Codable, Equatable, Sendable {
  public let code: MessageQuantificationDiagnosticCode
  public let values: [String]

  public init(code: MessageQuantificationDiagnosticCode, values: [String] = []) {
    self.code = code
    self.values = values
  }
}

public struct MessageQuantificationResult: Codable, Equatable, Sendable {
  public let eventID: String
  public let source: MessageQuantificationSource
  public let limitations: [MessageQuantificationLimitation]
  public let dimensions: [MessageDimensionScore]
  /// Nil only when no positive, finite dimension weight was configured.
  public let totalScore: Double?
  public let featureEvaluations: [MessageScoreFeatureEvaluation]
  public let diagnostics: [MessageQuantificationDiagnostic]

  public init(
    eventID: String,
    source: MessageQuantificationSource,
    limitations: [MessageQuantificationLimitation],
    dimensions: [MessageDimensionScore],
    totalScore: Double?,
    featureEvaluations: [MessageScoreFeatureEvaluation],
    diagnostics: [MessageQuantificationDiagnostic]
  ) {
    self.eventID = eventID
    self.source = source
    self.limitations = limitations
    self.dimensions = dimensions
    self.totalScore = totalScore
    self.featureEvaluations = featureEvaluations
    self.diagnostics = diagnostics
  }
}

public enum MessageQuantifier {
  public static func score(
    _ event: MessageEvent,
    configuration: MessageQuantificationConfiguration
  ) -> MessageQuantificationResult {
    guard configuration.schemaVersion
      == MessageQuantificationConfiguration.currentSchemaVersion
    else {
      return unsupportedConfigurationResult(event, configuration: configuration)
    }

    let duplicateFeatureIDs = duplicateFeatureIdentifiers(configuration.features.map(\.id))
    let orderedFeatures = configuration.features.enumerated().sorted { lhs, rhs in
      if lhs.element.priority != rhs.element.priority {
        return lhs.element.priority > rhs.element.priority
      }
      if lhs.element.id != rhs.element.id {
        return lhs.element.id < rhs.element.id
      }
      if lhs.element.name != rhs.element.name {
        return lhs.element.name < rhs.element.name
      }
      return lhs.offset < rhs.offset
    }

    var diagnostics: [MessageQuantificationDiagnostic] = []
    var featureEvaluations: [MessageScoreFeatureEvaluation] = []
    var appliedPoints = Dictionary(
      uniqueKeysWithValues: MessageQuantificationDimension.allCases.map { ($0, [Double]()) }
    )
    var appliedFeatureIDs = Dictionary(
      uniqueKeysWithValues: MessageQuantificationDimension.allCases.map { ($0, [String]()) }
    )

    for (_, feature) in orderedFeatures {
      let status: MessageScoreFeatureStatus
      let reasons: [MessageRuleReason]
      if !feature.isEnabled {
        status = .disabled
        reasons = []
      } else if feature.schemaVersion != MessageScoreFeature.currentSchemaVersion {
        status = .invalid
        reasons = [
          MessageRuleReason(
            code: .unsupportedSchemaVersion,
            outcome: .invalid,
            values: [String(feature.schemaVersion)]
          ),
        ]
        diagnostics.append(
          MessageQuantificationDiagnostic(
            code: .unsupportedSchemaVersion,
            values: ["feature", feature.id, String(feature.schemaVersion)]
          )
        )
      } else if trimmed(feature.id).isEmpty {
        status = .invalid
        reasons = []
        diagnostics.append(
          MessageQuantificationDiagnostic(code: .emptyFeatureIdentifier)
        )
      } else if duplicateFeatureIDs.contains(feature.id) {
        status = .invalid
        reasons = []
        diagnostics.append(
          MessageQuantificationDiagnostic(
            code: .duplicateFeatureIdentifier,
            values: [feature.id]
          )
        )
      } else if !feature.points.isFinite {
        status = .invalid
        reasons = []
        diagnostics.append(
          MessageQuantificationDiagnostic(
            code: .invalidFeaturePoints,
            values: [feature.id]
          )
        )
      } else {
        let conditionResult = MessageRuleEngine.evaluateCondition(
          event,
          condition: feature.condition
        )
        reasons = conditionResult.reasons
        switch conditionResult.status {
        case .matched:
          status = .applied
          appliedPoints[feature.dimension, default: []].append(feature.points)
          appliedFeatureIDs[feature.dimension, default: []].append(feature.id)
        case .notMatched:
          status = .notMatched
        case .invalid, .disabled:
          status = .invalid
        }
      }
      featureEvaluations.append(
        MessageScoreFeatureEvaluation(
          featureID: feature.id,
          featureName: feature.name,
          priority: feature.priority,
          dimension: feature.dimension,
          configuredPoints: feature.points.isFinite ? feature.points : 0,
          status: status,
          reasons: reasons
        )
      )
    }

    var validWeights: [MessageQuantificationDimension: Double] = [:]
    for dimension in MessageQuantificationDimension.allCases {
      let weight = configuration.weights.value(for: dimension)
      if weight.isFinite && weight >= 0 {
        validWeights[dimension] = weight
      } else {
        validWeights[dimension] = 0
        diagnostics.append(
          MessageQuantificationDiagnostic(
            code: .invalidWeight,
            values: [dimension.rawValue]
          )
        )
      }
    }
    let maximumWeight = MessageQuantificationDimension.allCases.reduce(0) {
      max($0, validWeights[$1, default: 0])
    }
    let scaledWeightSum = maximumWeight > 0
      ? MessageQuantificationDimension.allCases.reduce(0) {
        $0 + validWeights[$1, default: 0] / maximumWeight
      }
      : 0
    if scaledWeightSum == 0 {
      diagnostics.append(MessageQuantificationDiagnostic(code: .zeroWeightSum))
    }

    var dimensionScores: [MessageDimensionScore] = []
    for dimension in MessageQuantificationDimension.allCases {
      let configuredBaseline = configuration.baselines.value(for: dimension)
      let baseline: Double
      if configuredBaseline.isFinite {
        baseline = configuredBaseline
      } else {
        baseline = 0
        diagnostics.append(
          MessageQuantificationDiagnostic(
            code: .invalidBaseline,
            values: [dimension.rawValue]
          )
        )
      }
      let sumResult = stableFiniteSum(
        [baseline] + appliedPoints[dimension, default: []]
      )
      let rawScore = sumResult.value
      if sumResult.overflowed {
        diagnostics.append(
          MessageQuantificationDiagnostic(
            code: .scoreOverflow,
            values: [dimension.rawValue]
          )
        )
      }
      let score = min(100, max(0, rawScore))
      let configuredWeight = validWeights[dimension, default: 0]
      let normalizedWeight = scaledWeightSum > 0
        ? (configuredWeight / maximumWeight) / scaledWeightSum
        : 0
      dimensionScores.append(
        MessageDimensionScore(
          dimension: dimension,
          baseline: baseline,
          rawScore: rawScore,
          score: score,
          configuredWeight: configuredWeight,
          normalizedWeight: normalizedWeight,
          weightedContribution: score * normalizedWeight,
          appliedFeatureIDs: appliedFeatureIDs[dimension, default: []]
        )
      )
    }

    return MessageQuantificationResult(
      eventID: event.eventID,
      source: .ruleBased,
      limitations: [
        .capturedEventOnly,
        .collectionCompletenessNotMeasured,
        .semanticMeaningDependsOnConfiguredRules,
      ],
      dimensions: dimensionScores,
      totalScore: scaledWeightSum > 0
        ? dimensionScores.reduce(0) { $0 + $1.weightedContribution }
        : nil,
      featureEvaluations: featureEvaluations,
      diagnostics: diagnostics
    )
  }

  private static func duplicateFeatureIdentifiers(_ identifiers: [String]) -> Set<String> {
    var seen = Set<String>()
    var duplicates = Set<String>()
    for identifier in identifiers where !seen.insert(identifier).inserted {
      duplicates.insert(identifier)
    }
    return duplicates
  }

  private static func unsupportedConfigurationResult(
    _ event: MessageEvent,
    configuration: MessageQuantificationConfiguration
  ) -> MessageQuantificationResult {
    let dimensions = MessageQuantificationDimension.allCases.map {
      MessageDimensionScore(
        dimension: $0,
        baseline: 0,
        rawScore: 0,
        score: 0,
        configuredWeight: 0,
        normalizedWeight: 0,
        weightedContribution: 0,
        appliedFeatureIDs: []
      )
    }
    return MessageQuantificationResult(
      eventID: event.eventID,
      source: .ruleBased,
      limitations: [
        .capturedEventOnly,
        .collectionCompletenessNotMeasured,
        .semanticMeaningDependsOnConfiguredRules,
      ],
      dimensions: dimensions,
      totalScore: nil,
      featureEvaluations: [],
      diagnostics: [
        MessageQuantificationDiagnostic(
          code: .unsupportedSchemaVersion,
          values: ["configuration", String(configuration.schemaVersion)]
        ),
      ]
    )
  }
}

public struct MessageFlowNamedCount: Codable, Equatable, Sendable {
  public let name: String
  public let count: Int

  public init(name: String, count: Int) {
    self.name = name
    self.count = count
  }
}

public struct CapturedMessageFlowMetrics: Codable, Equatable, Sendable {
  public let inputEventCount: Int
  public let uniqueEventCount: Int
  public let duplicateEventIDCount: Int
  public let groupCount: Int
  /// Uses stable sender ID when present and display name otherwise.
  public let identifiedSenderKeyCount: Int
  public let unknownSenderEventCount: Int
  public let attachmentCount: Int
  public let selfAuthoredEventCount: Int
  public let firstObservedAt: Date?
  public let lastObservedAt: Date?
  public let eventsByGroup: [MessageFlowNamedCount]
  public let eventsByMessageType: [MessageFlowNamedCount]
  public let limitations: [MessageQuantificationLimitation]

  public init(
    inputEventCount: Int,
    uniqueEventCount: Int,
    duplicateEventIDCount: Int,
    groupCount: Int,
    identifiedSenderKeyCount: Int,
    unknownSenderEventCount: Int,
    attachmentCount: Int,
    selfAuthoredEventCount: Int,
    firstObservedAt: Date?,
    lastObservedAt: Date?,
    eventsByGroup: [MessageFlowNamedCount],
    eventsByMessageType: [MessageFlowNamedCount],
    limitations: [MessageQuantificationLimitation]
  ) {
    self.inputEventCount = inputEventCount
    self.uniqueEventCount = uniqueEventCount
    self.duplicateEventIDCount = duplicateEventIDCount
    self.groupCount = groupCount
    self.identifiedSenderKeyCount = identifiedSenderKeyCount
    self.unknownSenderEventCount = unknownSenderEventCount
    self.attachmentCount = attachmentCount
    self.selfAuthoredEventCount = selfAuthoredEventCount
    self.firstObservedAt = firstObservedAt
    self.lastObservedAt = lastObservedAt
    self.eventsByGroup = eventsByGroup
    self.eventsByMessageType = eventsByMessageType
    self.limitations = limitations
  }
}

public enum CapturedMessageFlowCounter {
  /// Counts only the supplied captured events and makes no claim about source completeness.
  public static func summarize(_ events: [MessageEvent]) -> CapturedMessageFlowMetrics {
    var uniqueEventsByID: [String: MessageEvent] = [:]
    for event in events where uniqueEventsByID[event.eventID] == nil {
      uniqueEventsByID[event.eventID] = event
    }
    let uniqueEvents = uniqueEventsByID.values.sorted(by: MessageEventOrder.precedes)

    var groupCounts: [String: Int] = [:]
    var typeCounts: [String: Int] = [:]
    var senderKeys = Set<String>()
    var unknownSenderEventCount = 0
    var attachmentCount = 0
    var selfAuthoredEventCount = 0

    for event in uniqueEvents {
      groupCounts[event.group, default: 0] += 1
      typeCounts[event.messageType.rawValue, default: 0] += 1
      if let stableID = event.senderStableID, !trimmed(stableID).isEmpty {
        senderKeys.insert("stable:\(stableID)")
      } else if let displayName = event.senderDisplayName,
                !trimmed(displayName).isEmpty
      {
        senderKeys.insert("display:\(displayName)")
      } else {
        unknownSenderEventCount += 1
      }
      attachmentCount += event.attachments.count
      if event.isFromSelf { selfAuthoredEventCount += 1 }
    }

    return CapturedMessageFlowMetrics(
      inputEventCount: events.count,
      uniqueEventCount: uniqueEvents.count,
      duplicateEventIDCount: events.count - uniqueEvents.count,
      groupCount: groupCounts.count,
      identifiedSenderKeyCount: senderKeys.count,
      unknownSenderEventCount: unknownSenderEventCount,
      attachmentCount: attachmentCount,
      selfAuthoredEventCount: selfAuthoredEventCount,
      firstObservedAt: uniqueEvents.first?.observedAt,
      lastObservedAt: uniqueEvents.last?.observedAt,
      eventsByGroup: groupCounts
        .map { MessageFlowNamedCount(name: $0.key, count: $0.value) }
        .sorted { $0.name < $1.name },
      eventsByMessageType: typeCounts
        .map { MessageFlowNamedCount(name: $0.key, count: $0.value) }
        .sorted { $0.name < $1.name },
      limitations: [.capturedEventOnly, .collectionCompletenessNotMeasured]
    )
  }
}
