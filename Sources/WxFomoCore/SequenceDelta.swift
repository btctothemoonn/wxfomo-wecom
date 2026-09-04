import Foundation

public struct SequenceDeltaResult<Element: Equatable>: Equatable {
  public let newItems: [Element]
  public let hadContinuity: Bool

  public init(newItems: [Element], hadContinuity: Bool) {
    self.newItems = newItems
    self.hadContinuity = hadContinuity
  }
}

public enum SequenceDelta {
  /// Finds the largest overlap between the previous suffix and current prefix.
  /// This remains correct when the UI drops rows from the top as it scrolls.
  public static func appended<Element: Equatable>(
    previous: [Element],
    current: [Element]
  ) -> SequenceDeltaResult<Element> {
    guard !previous.isEmpty else {
      return SequenceDeltaResult(newItems: current, hadContinuity: false)
    }
    guard !current.isEmpty else {
      return SequenceDeltaResult(newItems: [], hadContinuity: true)
    }

    let maximumOverlap = min(previous.count, current.count)
    if maximumOverlap > 0 {
      for overlap in stride(from: maximumOverlap, through: 1, by: -1) {
        if Array(previous.suffix(overlap)) == Array(current.prefix(overlap)) {
          return SequenceDeltaResult(
            newItems: Array(current.dropFirst(overlap)),
            hadContinuity: true
          )
        }
      }
    }

    return SequenceDeltaResult(newItems: current, hadContinuity: false)
  }
}
