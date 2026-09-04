import AppKit
import ImageIO
import SwiftUI
import WxFomoCore

struct TokenArtworkView: View {
  let snapshot: CATokenMarketSnapshot
  var size: CGFloat
  var cornerRadius: CGFloat
  @State private var loadedImage: NSImage?
  @State private var isLoading = false

  var body: some View {
    Group {
      if let loadedImage {
        Image(nsImage: loadedImage)
          .resizable()
          .scaledToFill()
      } else {
        placeholder
          .overlay {
            if isLoading {
              ProgressView().controlSize(.mini)
            }
          }
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    .overlay {
      RoundedRectangle(cornerRadius: cornerRadius)
        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
    }
    .accessibilityLabel("\(tokenTitle) 代币头像")
    .task(id: imageURL) {
      await loadImage()
    }
  }

  @MainActor
  private func loadImage() async {
    loadedImage = nil
    guard let imageURL else { return }

    if let cached = TokenArtworkImageCache.image(for: imageURL) {
      loadedImage = cached
      return
    }

    isLoading = true
    defer { isLoading = false }
    do {
      var request = URLRequest(url: imageURL)
      request.cachePolicy = .returnCacheDataElseLoad
      request.timeoutInterval = 12
      let (data, response) = try await URLSession.shared.data(for: request)
      guard !Task.isCancelled,
        let httpResponse = response as? HTTPURLResponse,
        (200..<300).contains(httpResponse.statusCode)
      else { return }

      // Decode a bounded thumbnail away from the main actor. Token logos are
      // displayed at at most 64pt, so retaining the original remote bitmap is
      // unnecessary and can create a large transient allocation while paging.
      let decoded = await Task.detached(priority: .utility) {
        Self.downsampledImage(from: data, maxPixelSize: 128)
      }.value
      guard !Task.isCancelled else { return }
      let image: NSImage?
      if let decoded {
        image = NSImage(
          cgImage: decoded,
          size: NSSize(width: decoded.width, height: decoded.height)
        )
      } else {
        // Do not decode an unbounded original when ImageIO cannot create a
        // thumbnail (for example, an unsupported or malformed asset).
        guard data.count <= 512 * 1024 else { return }
        image = NSImage(data: data)
      }
      guard let image else { return }
      let pixelCost = decoded.map { max($0.bytesPerRow * $0.height, 1) }
        ?? max(data.count, 1)
      TokenArtworkImageCache.insert(image, for: imageURL, byteCount: pixelCost)
      loadedImage = image
    } catch is CancellationError {
      return
    } catch {
      // The placeholder remains visible when an avatar is unavailable.
    }
  }

  nonisolated private static func downsampledImage(from data: Data, maxPixelSize: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  private var placeholder: some View {
    ZStack {
      RoundedRectangle(cornerRadius: cornerRadius)
        .fill(chainColor.opacity(0.14))
      if let initial = snapshot.symbol.first {
        Text(String(initial).uppercased())
          .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
          .foregroundStyle(chainColor)
      } else {
        Image(systemName: "bitcoinsign.circle.fill")
          .font(.system(size: size * 0.48, weight: .semibold))
          .foregroundStyle(chainColor)
      }
    }
  }

  private var imageURL: URL? {
    guard let value = snapshot.logoURL,
      let url = URL(string: value),
      url.scheme == "https",
      url.host != nil
    else { return nil }
    return url
  }

  private var tokenTitle: String {
    if !snapshot.symbol.isEmpty { return snapshot.symbol }
    if !snapshot.name.isEmpty { return snapshot.name }
    return "未知代币"
  }

  private var chainColor: Color {
    TokenChainBadge.color(for: snapshot.chain)
  }
}

private enum TokenArtworkImageCache {
  private static let cache: NSCache<NSURL, NSImage> = {
    let cache = NSCache<NSURL, NSImage>()
    // Keep the cache bounded so browsing many pages cannot retain every avatar.
    cache.countLimit = 96
    cache.totalCostLimit = 12 * 1024 * 1024
    return cache
  }()

  static func image(for url: URL) -> NSImage? {
    cache.object(forKey: url as NSURL)
  }

  static func insert(_ image: NSImage, for url: URL, byteCount: Int) {
    cache.setObject(image, forKey: url as NSURL, cost: max(byteCount, 1))
  }
}

struct TokenChainBadge: View {
  let chain: GMGNChain
  var compact = false

  var body: some View {
    HStack(spacing: compact ? 3 : 5) {
      Image(systemName: Self.symbol(for: chain))
        .font(.system(size: compact ? 8 : 10, weight: .bold))
        .frame(width: compact ? 12 : 15, height: compact ? 12 : 15)
        .background(Self.color(for: chain).opacity(0.16), in: Circle())
      Text(compact ? shortTitle : chain.localizedTitle)
        .font(.caption2.weight(.bold))
    }
    .foregroundStyle(Self.color(for: chain))
    .accessibilityLabel("\(chain.localizedTitle) 链")
  }

  static func color(for chain: GMGNChain) -> Color {
    switch chain {
    case .sol: return Color(red: 0.62, green: 0.32, blue: 0.95)
    case .eth: return Color(red: 0.38, green: 0.48, blue: 0.78)
    case .base: return Color(red: 0.05, green: 0.34, blue: 0.96)
    case .bsc: return Color(red: 0.92, green: 0.66, blue: 0.08)
    case .robinhood: return Color(red: 0.12, green: 0.72, blue: 0.42)
    }
  }

  private static func symbol(for chain: GMGNChain) -> String {
    switch chain {
    case .sol: return "line.3.horizontal"
    case .eth: return "diamond.fill"
    case .base: return "b.circle.fill"
    case .bsc: return "hexagon.fill"
    case .robinhood: return "leaf.fill"
    }
  }

  private var shortTitle: String {
    switch chain {
    case .sol: return "SOL"
    case .eth: return "ETH"
    case .base: return "Base"
    case .bsc: return "BSC"
    case .robinhood: return "RH"
    }
  }
}

enum TokenExternalLinks {
  static func gmgn(chain: GMGNChain, address: String) -> URL? {
    platformURL(
      host: "gmgn.ai",
      pathComponents: [chain.rawValue, "token", address]
    )
  }

  static func fomo(chain: GMGNChain, address: String) -> URL? {
    let chainSlug: String
    switch chain {
    case .sol: chainSlug = "solana"
    case .eth: chainSlug = "ethereum"
    case .base: chainSlug = "base"
    case .bsc: chainSlug = "bnb"
    case .robinhood: chainSlug = "robinhood"
    }
    return platformURL(
      host: "fomo.family",
      pathComponents: ["tokens", chainSlug, address]
    )
  }

  private static func platformURL(host: String, pathComponents: [String]) -> URL? {
    guard var url = URL(string: "https://\(host)") else { return nil }
    for component in pathComponents where !component.isEmpty {
      url.appendPathComponent(component)
    }
    return url
  }
}
