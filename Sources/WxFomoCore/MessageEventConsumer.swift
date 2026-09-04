import Foundation

public enum MessageEventDisplayUpdate: Equatable, Sendable {
  case unchanged
  case reloadFromStore
  case replaceInMemory([MessageEvent])
}

public struct MessageEventConsumption: Equatable, Sendable {
  public let displayUpdate: MessageEventDisplayUpdate
  public let shouldRunNewMessageSideEffects: Bool

  public init(
    displayUpdate: MessageEventDisplayUpdate,
    shouldRunNewMessageSideEffects: Bool
  ) {
    self.displayUpdate = displayUpdate
    self.shouldRunNewMessageSideEffects = shouldRunNewMessageSideEffects
  }

  public var representsMessageUpdate: Bool {
    guard !shouldRunNewMessageSideEffects else { return false }
    switch displayUpdate {
    case .unchanged:
      return false
    case .reloadFromStore, .replaceInMemory:
      return true
    }
  }
}

public enum MessageEventConsumer {
  public static func persisted(_ result: MessageInsertResult) -> MessageEventConsumption {
    switch result {
    case .inserted:
      return MessageEventConsumption(
        displayUpdate: .reloadFromStore,
        shouldRunNewMessageSideEffects: true
      )
    case .updated:
      return MessageEventConsumption(
        displayUpdate: .reloadFromStore,
        shouldRunNewMessageSideEffects: false
      )
    case .existing:
      return MessageEventConsumption(
        displayUpdate: .unchanged,
        shouldRunNewMessageSideEffects: false
      )
    }
  }

  public static func withoutStore(
    _ event: MessageEvent,
    displayedMessages: [MessageEvent]
  ) -> MessageEventConsumption {
    let existing = displayedMessages.first { $0.eventID == event.eventID }
    if let existing = existing,
      (existing.group != event.group
        || event.observedAt < existing.observedAt
        || existing == event)
    {
      return MessageEventConsumption(
        displayUpdate: .unchanged,
        shouldRunNewMessageSideEffects: false
      )
    }
    var merged = displayedMessages.filter { $0.eventID != event.eventID }
    merged.append(event)
    merged.sort(by: MessageEventOrder.latestFirst)
    return MessageEventConsumption(
      displayUpdate: .replaceInMemory(merged),
      shouldRunNewMessageSideEffects: existing == nil
    )
  }
}
