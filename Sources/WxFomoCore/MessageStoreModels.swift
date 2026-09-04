import Foundation

public struct MessageStoreCapabilities: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let journalMode: String
  public let fullTextSearchAvailable: Bool

  public init(schemaVersion: Int, journalMode: String, fullTextSearchAvailable: Bool) {
    self.schemaVersion = schemaVersion
    self.journalMode = journalMode
    self.fullTextSearchAvailable = fullTextSearchAvailable
  }
}

public enum MessageInsertResult: String, Codable, Equatable, Sendable {
  case inserted
  case updated
  case existing
}

public struct MessageBatchInsertResult: Codable, Equatable, Sendable {
  public let insertedCount: Int
  public let existingCount: Int

  public init(insertedCount: Int, existingCount: Int) {
    self.insertedCount = insertedCount
    self.existingCount = existingCount
  }
}

public struct MessageScopeAnyMatch: Codable, Equatable, Sendable {
  public var tagIDs: Set<String>
  public var terms: Set<String>

  public init(tagIDs: Set<String> = [], terms: Set<String> = []) {
    self.tagIDs = tagIDs
    self.terms = terms
  }
}

public struct MessageScope: Codable, Equatable, Sendable {
  public var groups: Set<String>
  public var startDate: Date?
  public var endDate: Date?
  public var messageTypes: Set<MessageKind>
  public var searchText: String?
  public var senders: Set<String>
  public var tagIDs: Set<String>
  public var excludedTagIDs: Set<String>
  public var includeAnyTerms: Set<String>
  public var excludeAnyTerms: Set<String>
  public var contentContainsAnyTerms: Set<String>
  public var requiresKnownSender: Bool
  public var afterReviewCursors: [ReviewCursor]
  public var anyMatch: MessageScopeAnyMatch?

  public init(
    groups: Set<String> = [],
    startDate: Date? = nil,
    endDate: Date? = nil,
    messageTypes: Set<MessageKind> = [],
    searchText: String? = nil,
    senders: Set<String> = [],
    tagIDs: Set<String> = [],
    excludedTagIDs: Set<String> = [],
    includeAnyTerms: Set<String> = [],
    excludeAnyTerms: Set<String> = [],
    contentContainsAnyTerms: Set<String> = [],
    requiresKnownSender: Bool = false,
    afterReviewCursors: [ReviewCursor] = [],
    anyMatch: MessageScopeAnyMatch? = nil
  ) {
    self.groups = groups
    self.startDate = startDate
    self.endDate = endDate
    self.messageTypes = messageTypes
    self.searchText = searchText
    self.senders = senders
    self.tagIDs = tagIDs
    self.excludedTagIDs = excludedTagIDs
    self.includeAnyTerms = includeAnyTerms
    self.excludeAnyTerms = excludeAnyTerms
    self.contentContainsAnyTerms = contentContainsAnyTerms
    self.requiresKnownSender = requiresKnownSender
    self.afterReviewCursors = afterReviewCursors
    self.anyMatch = anyMatch
  }

  private enum CodingKeys: String, CodingKey {
    case groups
    case startDate
    case endDate
    case messageTypes
    case searchText
    case senders
    case tagIDs
    case excludedTagIDs
    case includeAnyTerms
    case excludeAnyTerms
    case contentContainsAnyTerms
    case requiresKnownSender
    case afterReviewCursors
    case anyMatch
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    groups = try container.decodeIfPresent(Set<String>.self, forKey: .groups) ?? []
    startDate = try container.decodeIfPresent(Date.self, forKey: .startDate)
    endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
    messageTypes = try container.decodeIfPresent(Set<MessageKind>.self, forKey: .messageTypes) ?? []
    searchText = try container.decodeIfPresent(String.self, forKey: .searchText)
    senders = try container.decodeIfPresent(Set<String>.self, forKey: .senders) ?? []
    tagIDs = try container.decodeIfPresent(Set<String>.self, forKey: .tagIDs) ?? []
    excludedTagIDs = try container.decodeIfPresent(Set<String>.self, forKey: .excludedTagIDs) ?? []
    includeAnyTerms = try container.decodeIfPresent(Set<String>.self, forKey: .includeAnyTerms) ?? []
    excludeAnyTerms = try container.decodeIfPresent(Set<String>.self, forKey: .excludeAnyTerms) ?? []
    contentContainsAnyTerms = try container.decodeIfPresent(
      Set<String>.self,
      forKey: .contentContainsAnyTerms
    ) ?? []
    requiresKnownSender = try container.decodeIfPresent(
      Bool.self,
      forKey: .requiresKnownSender
    ) ?? false
    afterReviewCursors = try container.decodeIfPresent(
      [ReviewCursor].self,
      forKey: .afterReviewCursors
    ) ?? []
    anyMatch = try container.decodeIfPresent(MessageScopeAnyMatch.self, forKey: .anyMatch)
  }
}

public enum MessageSortOrder: String, Codable, Equatable, Sendable {
  case newestFirst = "newest_first"
  case oldestFirst = "oldest_first"
}

public struct MessagePageCursor: Codable, Equatable, Sendable {
  public let storageID: Int64
  public let eventID: String
  public let observedAt: Date
  public let sourceSequence: Int64?
  public let order: MessageSortOrder

  public init(
    storageID: Int64,
    eventID: String,
    observedAt: Date,
    sourceSequence: Int64?,
    order: MessageSortOrder
  ) {
    self.storageID = storageID
    self.eventID = eventID
    self.observedAt = observedAt
    self.sourceSequence = sourceSequence
    self.order = order
  }
}

public struct MessageQuery: Codable, Equatable, Sendable {
  public var scope: MessageScope
  public var limit: Int
  public var after: MessagePageCursor?
  public var order: MessageSortOrder

  public init(
    scope: MessageScope = MessageScope(),
    limit: Int = 100,
    after: MessagePageCursor? = nil,
    order: MessageSortOrder = .newestFirst
  ) {
    self.scope = scope
    self.limit = limit
    self.after = after
    self.order = order
  }
}

public struct StoredMessage: Codable, Equatable, Sendable {
  public let storageID: Int64
  public let event: MessageEvent
  public let insertedAt: Date
  public let tagIDs: [String]

  public init(
    storageID: Int64,
    event: MessageEvent,
    insertedAt: Date,
    tagIDs: [String] = []
  ) {
    self.storageID = storageID
    self.event = event
    self.insertedAt = insertedAt
    self.tagIDs = tagIDs
  }
}

public struct MessagePage: Codable, Equatable, Sendable {
  public let messages: [StoredMessage]
  public let nextCursor: MessagePageCursor?
  public let hasMore: Bool

  public init(
    messages: [StoredMessage],
    nextCursor: MessagePageCursor?,
    hasMore: Bool
  ) {
    self.messages = messages
    self.nextCursor = nextCursor
    self.hasMore = hasMore
  }
}

public struct MessageRangeStatistics: Codable, Equatable, Sendable {
  public let capturedCount: Int
  public let conversationCount: Int
  public let senderCount: Int
  public let mediaPlaceholderCount: Int
  public let unknownSenderCount: Int
  public let earliestObservedAt: Date?
  public let latestObservedAt: Date?

  public init(
    capturedCount: Int,
    conversationCount: Int,
    senderCount: Int,
    mediaPlaceholderCount: Int,
    unknownSenderCount: Int,
    earliestObservedAt: Date?,
    latestObservedAt: Date?
  ) {
    self.capturedCount = capturedCount
    self.conversationCount = conversationCount
    self.senderCount = senderCount
    self.mediaPlaceholderCount = mediaPlaceholderCount
    self.unknownSenderCount = unknownSenderCount
    self.earliestObservedAt = earliestObservedAt
    self.latestObservedAt = latestObservedAt
  }
}

/// Metrics for notification records captured on this Mac and managed inside wxFomo.
/// `pendingReviewCount` means after wxFomo's per-group review cursor; it is not WeChat unread.
public struct MessageManagementMetrics: Codable, Equatable, Sendable {
  public let baseCapturedCount: Int
  public let unsuppressedCapturedCount: Int
  public let priorityCapturedCount: Int
  public let suppressedCapturedCount: Int
  public let pendingReviewCount: Int
  public let oldestPendingReviewObservedAt: Date?

  public init(
    baseCapturedCount: Int,
    unsuppressedCapturedCount: Int,
    priorityCapturedCount: Int,
    suppressedCapturedCount: Int,
    pendingReviewCount: Int,
    oldestPendingReviewObservedAt: Date?
  ) {
    self.baseCapturedCount = baseCapturedCount
    self.unsuppressedCapturedCount = unsuppressedCapturedCount
    self.priorityCapturedCount = priorityCapturedCount
    self.suppressedCapturedCount = suppressedCapturedCount
    self.pendingReviewCount = pendingReviewCount
    self.oldestPendingReviewObservedAt = oldestPendingReviewObservedAt
  }

  /// Share of currently unsuppressed captured notifications that match the priority criteria.
  public var priorityRate: Double? {
    guard unsuppressedCapturedCount > 0 else { return nil }
    return Double(priorityCapturedCount) / Double(unsuppressedCapturedCount)
  }

  /// Share of the base captured-notification set that wxFomo currently suppresses.
  public var suppressionRate: Double? {
    guard baseCapturedCount > 0 else { return nil }
    return Double(suppressedCapturedCount) / Double(baseCapturedCount)
  }
}

/// Fixed-duration buckets keep historical charts deterministic across locale and time-zone changes.
public enum FlowAnalyticsBucketGranularity: String, Codable, Equatable, Sendable {
  case fiveMinutes = "five_minutes"
  case fifteenMinutes = "fifteen_minutes"
  case sixtyMinutes = "sixty_minutes"
  case sixHours = "six_hours"
  case twentyFourHours = "twenty_four_hours"
  case sevenDays = "seven_days"
  case thirtyDays = "thirty_days"
  case ninetyDays = "ninety_days"
  case threeHundredSixtyFiveDays = "three_hundred_sixty_five_days"

  public var duration: TimeInterval {
    switch self {
    case .fiveMinutes: return 5 * 60
    case .fifteenMinutes: return 15 * 60
    case .sixtyMinutes: return 60 * 60
    case .sixHours: return 6 * 60 * 60
    case .twentyFourHours: return 24 * 60 * 60
    case .sevenDays: return 7 * 24 * 60 * 60
    case .thirtyDays: return 30 * 24 * 60 * 60
    case .ninetyDays: return 90 * 24 * 60 * 60
    case .threeHundredSixtyFiveDays: return 365 * 24 * 60 * 60
    }
  }
}

public struct FlowAnalyticsTimeBucket: Codable, Equatable, Sendable {
  public let startDate: Date
  public let endDate: Date
  public let capturedCount: Int

  public init(startDate: Date, endDate: Date, capturedCount: Int) {
    self.startDate = startDate
    self.endDate = endDate
    self.capturedCount = capturedCount
  }
}

public struct FlowAnalyticsGroupDistribution: Codable, Equatable, Sendable {
  public let group: String
  public let capturedCount: Int

  public init(group: String, capturedCount: Int) {
    self.group = group
    self.capturedCount = capturedCount
  }
}

public struct FlowAnalyticsSenderDistribution: Codable, Equatable, Sendable {
  /// Stable IDs take precedence over display names. Unknown senders share the `unknown` key.
  public let identityKey: String
  public let displayName: String?
  public let stableID: String?
  public let capturedCount: Int

  public init(
    identityKey: String,
    displayName: String?,
    stableID: String?,
    capturedCount: Int
  ) {
    self.identityKey = identityKey
    self.displayName = displayName
    self.stableID = stableID
    self.capturedCount = capturedCount
  }
}

public struct FlowAnalyticsMessageTypeDistribution: Codable, Equatable, Sendable {
  public let messageType: MessageKind
  public let capturedCount: Int

  public init(messageType: MessageKind, capturedCount: Int) {
    self.messageType = messageType
    self.capturedCount = capturedCount
  }
}

/// Quantifies only messages already captured in the local store. It makes no collection-coverage claim.
public struct MessageFlowAnalytics: Codable, Equatable, Sendable {
  public let statistics: MessageRangeStatistics
  public let bucketGranularity: FlowAnalyticsBucketGranularity
  public let timeBuckets: [FlowAnalyticsTimeBucket]
  public let groupDistribution: [FlowAnalyticsGroupDistribution]
  public let senderDistribution: [FlowAnalyticsSenderDistribution]
  public let messageTypeDistribution: [FlowAnalyticsMessageTypeDistribution]
  public let peakBucketCount: Int

  public init(
    statistics: MessageRangeStatistics,
    bucketGranularity: FlowAnalyticsBucketGranularity,
    timeBuckets: [FlowAnalyticsTimeBucket],
    groupDistribution: [FlowAnalyticsGroupDistribution],
    senderDistribution: [FlowAnalyticsSenderDistribution],
    messageTypeDistribution: [FlowAnalyticsMessageTypeDistribution]
  ) {
    self.statistics = statistics
    self.bucketGranularity = bucketGranularity
    self.timeBuckets = timeBuckets
    self.groupDistribution = groupDistribution
    self.senderDistribution = senderDistribution
    self.messageTypeDistribution = messageTypeDistribution
    peakBucketCount = timeBuckets.map(\.capturedCount).max() ?? 0
  }
}

public struct ReviewCursor: Codable, Equatable, Sendable {
  public let group: String
  public let eventID: String
  public let observedAt: Date
  public let sourceSequence: Int64?
  public let updatedAt: Date

  public init(
    group: String,
    eventID: String,
    observedAt: Date,
    sourceSequence: Int64?,
    updatedAt: Date
  ) {
    self.group = group
    self.eventID = eventID
    self.observedAt = observedAt
    self.sourceSequence = sourceSequence
    self.updatedAt = updatedAt
  }
}

public struct MessageTag: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let colorHex: String?
  public let createdAt: Date

  public init(id: String, name: String, colorHex: String?, createdAt: Date) {
    self.id = id
    self.name = name
    self.colorHex = colorHex
    self.createdAt = createdAt
  }
}

public struct FrozenMessageRange: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let createdAt: Date
  public let scope: MessageScope
  public let eventIDs: [String]
  public let earliestObservedAt: Date?
  public let latestObservedAt: Date?

  public init(
    id: String,
    createdAt: Date,
    scope: MessageScope,
    eventIDs: [String],
    earliestObservedAt: Date?,
    latestObservedAt: Date?
  ) {
    self.id = id
    self.createdAt = createdAt
    self.scope = scope
    self.eventIDs = eventIDs
    self.earliestObservedAt = earliestObservedAt
    self.latestObservedAt = latestObservedAt
  }
}
