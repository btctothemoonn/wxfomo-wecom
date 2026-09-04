import Foundation

public struct OCRMessageExtractor: Sendable {
  public init() {}

  public func extract(
    lines: [OCRLine],
    group: String,
    contentMinX: Double,
    contentMaxX: Double = 0.985,
    contentMinY: Double = 0.08,
    contentMaxY: Double = 0.76
  ) -> [RawMessageRow] {
    let width = max(0.01, contentMaxX - contentMinX)
    let candidates = lines.compactMap { line -> OCRLine? in
      guard
        line.frame.x + line.frame.width >= contentMinX,
        line.frame.x <= contentMaxX,
        line.frame.y >= contentMinY,
        line.frame.y + line.frame.height <= contentMaxY,
        normalized(line.text) != normalized(group),
        !isTimestamp(line.text)
      else {
        return nil
      }
      return OCRLine(
        text: line.text,
        frame: ElementFrame(
          x: max(0, (line.frame.x - contentMinX) / width),
          y: line.frame.y,
          width: min(1, line.frame.width / width),
          height: line.frame.height
        ),
        confidence: line.confidence
      )
    }.sorted {
      if abs($0.frame.y - $1.frame.y) > 0.012 {
        return $0.frame.y < $1.frame.y
      }
      return $0.frame.x < $1.frame.x
    }

    var rows: [RawMessageRow] = []
    var pendingSender: OCRLine?
    var index = 0

    while index < candidates.count {
      let line = candidates[index]
      let next = candidates.indices.contains(index + 1) ? candidates[index + 1] : nil

      if let next, isLikelySender(line, followedBy: next) {
        pendingSender = line
        index += 1
        continue
      }

      let midpoint = line.frame.x + line.frame.width / 2
      if midpoint >= 0.62 {
        rows.append(
          RawMessageRow(
            labels: ["我说：\(line.text)"],
            frame: line.frame
          ))
        pendingSender = nil
      } else if midpoint <= 0.58 {
        if let sender = pendingSender,
          line.frame.y - (sender.frame.y + sender.frame.height) <= 0.065
        {
          rows.append(
            RawMessageRow(
              labels: [sender.text, line.text],
              frame: line.frame
            ))
        } else {
          rows.append(RawMessageRow(labels: [line.text], frame: line.frame))
        }
        pendingSender = nil
      } else {
        rows.append(RawMessageRow(labels: [line.text], frame: line.frame))
        pendingSender = nil
      }
      index += 1
    }

    return rows
  }

  private func isLikelySender(_ line: OCRLine, followedBy next: OCRLine) -> Bool {
    let lineMidpoint = line.frame.x + line.frame.width / 2
    let nextMidpoint = next.frame.x + next.frame.width / 2
    let verticalGap = next.frame.y - (line.frame.y + line.frame.height)
    let horizontalInset = next.frame.x - line.frame.x
    let visiblySmaller = line.frame.height <= next.frame.height * 0.84
    let indentedBubble = horizontalInset >= 0.012 && horizontalInset <= 0.10

    return lineMidpoint < 0.55 && nextMidpoint < 0.58 && line.text.count <= 40
      && verticalGap >= 0.002 && verticalGap <= 0.055 && next.frame.x >= line.frame.x
      && (visiblySmaller || indentedBubble)
  }

  private func isTimestamp(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let patterns = [
      #"^\d{1,2}:\d{2}$"#,
      #"^\d{4}[/-]\d{1,2}[/-]\d{1,2}"#,
      #"^(昨天|今天|星期[一二三四五六日天]|周[一二三四五六日天])"#,
      #"^(Yesterday|Today|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)"#,
    ]
    return patterns.contains {
      trimmed.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
    }
  }

  private func normalized(_ value: String) -> String {
    value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
  }
}
