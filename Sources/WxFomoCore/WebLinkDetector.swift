import Foundation

/// A web URL explicitly written with an HTTP or HTTPS scheme in a local message.
public struct WebLinkMatch: Equatable, Hashable, Identifiable, Sendable {
  public let rawValue: String
  public let url: URL

  public var id: String { url.absoluteString }

  public init(rawValue: String, url: URL) {
    self.rawValue = rawValue
    self.url = url
  }
}

public enum WebLinkDetector {
  private static let detector = try! NSDataDetector(
    types: NSTextCheckingResult.CheckingType.link.rawValue
  )

  /// Returns unique, explicit HTTP/HTTPS URLs in deterministic message order.
  public static func matches(in content: String) -> [WebLinkMatch] {
    let searchRange = NSRange(content.startIndex..<content.endIndex, in: content)
    var seen = Set<String>()

    return detector.matches(in: content, range: searchRange).compactMap { result in
      guard result.resultType == .link,
        let range = Range(result.range, in: content),
        let url = result.url
      else { return nil }

      let rawValue = String(content[range])
      let normalizedPrefix = rawValue.lowercased()
      guard normalizedPrefix.hasPrefix("http://") || normalizedPrefix.hasPrefix("https://") else {
        return nil
      }
      guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
        return nil
      }
      guard seen.insert(url.absoluteString).inserted else { return nil }
      return WebLinkMatch(rawValue: rawValue, url: url)
    }
  }
}
