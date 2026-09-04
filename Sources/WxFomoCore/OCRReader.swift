import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

public enum OCRReaderError: LocalizedError {
  case screenCapturePermissionMissing
  case noWeChatWindows
  case captureFailed(UInt32)
  case groupWindowNotFound(String)

  public var errorDescription: String? {
    switch self {
    case .screenCapturePermissionMissing:
      return "缺少屏幕与系统音频录制权限"
    case .noWeChatWindows:
      return "没有找到可捕获的微信窗口"
    case .captureFailed(let windowID):
      return "微信窗口 \(windowID) 捕获失败"
    case .groupWindowNotFound(let group):
      return "没有找到标题或顶部群名匹配“\(group)”的微信窗口"
    }
  }
}

public final class WeChatOCRReader {
  private let extractor: OCRMessageExtractor

  public init(extractor: OCRMessageExtractor = OCRMessageExtractor()) {
    self.extractor = extractor
  }

  public func snapshot(
    group: String,
    boundWindowID: UInt32? = nil
  ) async throws -> OCRGroupSnapshot {
    guard CGPreflightScreenCaptureAccess() else {
      throw OCRReaderError.screenCapturePermissionMissing
    }

    let windows = try await weChatWindows()
    if let boundWindowID,
      let window = windows.first(where: { $0.windowID == boundWindowID })
    {
      let lines = try await recognize(window: window)
      if let match = match(window: window, lines: lines, group: group) {
        return makeSnapshot(window: window, lines: lines, group: group, match: match)
      }
    }

    if let window = windows.first(where: { normalized($0.title ?? "") == normalized(group) }) {
      let lines = try await recognize(window: window)
      return makeSnapshot(
        window: window,
        lines: lines,
        group: group,
        match: (.exactWindowTitle, 0)
      )
    }

    for window in windows {
      let lines = try await recognize(window: window)
      if let match = match(window: window, lines: lines, group: group) {
        return makeSnapshot(window: window, lines: lines, group: group, match: match)
      }
    }
    throw OCRReaderError.groupWindowNotFound(group)
  }

  public func probe(maximumLinesPerWindow: Int = 100) async throws -> [OCRWindowProbe] {
    guard CGPreflightScreenCaptureAccess() else {
      throw OCRReaderError.screenCapturePermissionMissing
    }

    let windows = try await weChatWindows()

    var reports: [OCRWindowProbe] = []
    for window in windows {
      let lines = try await recognize(window: window)
      let title = window.title.map {
        ProbeLabel(length: $0.count, digest: StableHash.hex($0))
      }
      reports.append(
        OCRWindowProbe(
          windowID: window.windowID,
          title: title,
          frame: ElementFrame(
            x: window.frame.origin.x,
            y: window.frame.origin.y,
            width: window.frame.width,
            height: window.frame.height
          ),
          lines: Array(lines.prefix(max(1, maximumLinesPerWindow)))
        ))
    }
    return reports
  }

  private func weChatWindows() async throws -> [SCWindow] {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: true
    )
    let windows = content.windows.filter {
      $0.owningApplication?.bundleIdentifier == WeChatAccessibilityReader.bundleIdentifier
        && $0.frame.width >= 300 && $0.frame.height >= 300
    }
    guard !windows.isEmpty else {
      throw OCRReaderError.noWeChatWindows
    }
    return windows
  }

  private func match(
    window: SCWindow,
    lines: [OCRLine],
    group: String
  ) -> (SnapshotConfidence, Double)? {
    if normalized(window.title ?? "") == normalized(group) {
      return (.exactWindowTitle, 0)
    }

    let header = lines.first { line in
      line.frame.y < 0.11 && normalized(line.text).contains(normalized(group))
    }
    guard let header else { return nil }
    let contentMinX = window.frame.width >= 680 && header.frame.x >= 0.35 ? 0.50 : 0
    return (.nearbyGroupLabel, contentMinX)
  }

  private func makeSnapshot(
    window: SCWindow,
    lines: [OCRLine],
    group: String,
    match: (SnapshotConfidence, Double)
  ) -> OCRGroupSnapshot {
    let rows = extractor.extract(
      lines: lines,
      group: group,
      contentMinX: match.1
    )
    return OCRGroupSnapshot(
      group: group,
      windowID: window.windowID,
      bindingKey: "ocr:\(window.windowID):\(StableHash.hex(group))",
      confidence: match.0,
      rows: rows,
      recognizedLines: lines
    )
  }

  private func normalized(_ value: String) -> String {
    value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
  }

  private func recognize(window: SCWindow) async throws -> [OCRLine] {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let configuration = SCStreamConfiguration()
    // SCScreenshotManager already renders a desktop-independent window at
    // the configured size. Doubling this creates an empty lower-right area
    // instead of increasing OCR resolution.
    configuration.width = max(1, Int(window.frame.width.rounded()))
    configuration.height = max(1, Int(window.frame.height.rounded()))
    configuration.showsCursor = false
    configuration.captureResolution = .best
    configuration.ignoreShadowsSingleWindow = true

    let image = try await SCScreenshotManager.captureImage(
      contentFilter: filter,
      configuration: configuration
    )
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
    request.usesLanguageCorrection = true
    request.minimumTextHeight = 0.009

    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])
    let observations = request.results ?? []
    let lines = observations.compactMap { observation -> OCRLine? in
      guard let candidate = observation.topCandidates(1).first else { return nil }
      let box = observation.boundingBox
      return OCRLine(
        text: candidate.string,
        frame: ElementFrame(
          x: box.origin.x,
          y: 1 - box.origin.y - box.height,
          width: box.width,
          height: box.height
        ),
        confidence: candidate.confidence
      )
    }
    return lines.sorted {
      if abs($0.frame.y - $1.frame.y) > 0.012 {
        return $0.frame.y < $1.frame.y
      }
      return $0.frame.x < $1.frame.x
    }
  }
}
