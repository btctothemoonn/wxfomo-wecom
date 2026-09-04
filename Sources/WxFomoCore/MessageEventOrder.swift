import Foundation

public enum MessageEventOrder {
  public static func precedes(_ lhs: MessageEvent, _ rhs: MessageEvent) -> Bool {
    if lhs.observedAt != rhs.observedAt {
      return lhs.observedAt < rhs.observedAt
    }
    switch (lhs.sourceSequence, rhs.sourceSequence) {
    case let (left?, right?) where left != right:
      return left < right
    case (_?, nil):
      return true
    case (nil, _?):
      return false
    default:
      return lhs.eventID < rhs.eventID
    }
  }

  public static func latestFirst(_ lhs: MessageEvent, _ rhs: MessageEvent) -> Bool {
    precedes(rhs, lhs)
  }
}
