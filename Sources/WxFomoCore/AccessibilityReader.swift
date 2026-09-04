import AppKit
import ApplicationServices
import Foundation

public enum WeChatReaderError: LocalizedError {
  case accessibilityPermissionMissing
  case weChatNotRunning
  case noWindows
  case groupWindowNotFound(String)

  public var errorDescription: String? {
    switch self {
    case .accessibilityPermissionMissing:
      return "缺少 macOS 辅助功能权限"
    case .weChatNotRunning:
      return "微信客户端未运行或未登录"
    case .noWindows:
      return "未找到可读取的微信窗口"
    case .groupWindowNotFound(let group):
      return "没有找到群聊“\(group)”对应的已打开消息窗口"
    }
  }
}

private enum AXRead {
  static func value(_ element: AXUIElement, attribute: CFString) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &result) == .success else {
      return nil
    }
    return result
  }

  static func string(_ element: AXUIElement, attribute: CFString) -> String? {
    value(element, attribute: attribute) as? String
  }

  static func elements(_ element: AXUIElement, attribute: CFString) -> [AXUIElement] {
    value(element, attribute: attribute) as? [AXUIElement] ?? []
  }

  static func children(_ element: AXUIElement) -> [AXUIElement] {
    elements(element, attribute: kAXChildrenAttribute as CFString)
  }

  static func role(_ element: AXUIElement) -> String {
    string(element, attribute: kAXRoleAttribute as CFString) ?? ""
  }

  static func frame(_ element: AXUIElement) -> ElementFrame? {
    guard
      let rawPosition = value(element, attribute: kAXPositionAttribute as CFString),
      let rawSize = value(element, attribute: kAXSizeAttribute as CFString),
      CFGetTypeID(rawPosition) == AXValueGetTypeID(),
      CFGetTypeID(rawSize) == AXValueGetTypeID()
    else {
      return nil
    }

    let positionValue = unsafeBitCast(rawPosition, to: AXValue.self)
    let sizeValue = unsafeBitCast(rawSize, to: AXValue.self)
    var point = CGPoint.zero
    var size = CGSize.zero
    guard
      AXValueGetValue(positionValue, .cgPoint, &point),
      AXValueGetValue(sizeValue, .cgSize, &size)
    else {
      return nil
    }
    return ElementFrame(
      x: point.x,
      y: point.y,
      width: size.width,
      height: size.height
    )
  }

  static func labels(_ element: AXUIElement) -> [String] {
    let attributes: [CFString] = [
      "AXName" as CFString,
      kAXTitleAttribute as CFString,
      kAXValueAttribute as CFString,
      kAXDescriptionAttribute as CFString,
      kAXHelpAttribute as CFString,
    ]
    var result: [String] = []
    var seen = Set<String>()

    for attribute in attributes {
      guard let raw = string(element, attribute: attribute) else { continue }
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, text.count <= 8_192, !seen.contains(text) else { continue }
      seen.insert(text)
      result.append(text)
    }
    return result
  }
}

private struct AXNode {
  let element: AXUIElement
  let role: String
  let frame: ElementFrame?
  let labels: [String]
  let depth: Int
  let childCount: Int
}

private struct TableCandidate {
  let element: AXUIElement
  let windowTitle: String
  let tableFrame: ElementFrame?
  let confidence: SnapshotConfidence
  let score: Double
  let rows: [RawMessageRow]

  var bindingKey: String {
    let frameKey: String
    if let tableFrame {
      frameKey = [tableFrame.x, tableFrame.y, tableFrame.width, tableFrame.height]
        .map { String(Int($0.rounded())) }
        .joined(separator: ":")
    } else {
      frameKey = "no-frame"
    }
    return "\(windowTitle)|\(frameKey)"
  }
}

public final class WeChatAccessibilityReader {
  public static let bundleIdentifier = "com.tencent.xinWeChat"

  public init() {}

  public func doctor(promptForPermission: Bool = false) -> DoctorReport {
    let applicationURL = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: WeComNotificationPolicy.applicationBundleIdentifier
    )
    let version =
      applicationURL
      .flatMap(Bundle.init(url:))?
      .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    let trusted: Bool
    if promptForPermission {
      let options =
        [
          kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
      trusted = AXIsProcessTrustedWithOptions(options)
    } else {
      trusted = AXIsProcessTrusted()
    }

    var screenCaptureTrusted = CGPreflightScreenCaptureAccess()
    if promptForPermission, !screenCaptureTrusted {
      screenCaptureTrusted = CGRequestScreenCaptureAccess()
    }

    return DoctorReport(
      accessibilityTrusted: trusted,
      screenCaptureTrusted: screenCaptureTrusted,
      notificationDatabaseReadable: NotificationDatabaseReader().isReadable,
      weChatInstalled: applicationURL != nil,
      weChatRunning: !NSRunningApplication.runningApplications(
        withBundleIdentifier: WeComNotificationPolicy.applicationBundleIdentifier
      ).isEmpty,
      weChatVersion: version
    )
  }

  public func readSnapshot(
    group: String,
    allowSingleGroupFallback: Bool
  ) throws -> GroupSnapshot {
    let candidate = try selectTable(
      group: group,
      allowSingleGroupFallback: allowSingleGroupFallback
    )
    return GroupSnapshot(
      group: group,
      bindingKey: candidate.bindingKey,
      confidence: candidate.confidence,
      rows: candidate.rows
    )
  }

  public func inspect(
    group: String,
    allowSingleGroupFallback: Bool,
    rowLimit: Int
  ) throws -> InspectionReport {
    let candidate = try selectTable(
      group: group,
      allowSingleGroupFallback: allowSingleGroupFallback
    )
    return InspectionReport(
      group: group,
      windowTitle: candidate.windowTitle,
      tableFrame: candidate.tableFrame,
      confidence: candidate.confidence,
      rows: candidate.rows.suffix(max(1, rowLimit)).map {
        InspectionRow(frame: $0.frame, labels: $0.labels)
      }
    )
  }

  public func probe(maximumNodesPerWindow: Int = 300) throws -> [ProbeWindow] {
    guard AXIsProcessTrusted() else {
      throw WeChatReaderError.accessibilityPermissionMissing
    }
    guard let runningApplication = runningWeChat() else {
      throw WeChatReaderError.weChatNotRunning
    }

    let application = AXUIElementCreateApplication(runningApplication.processIdentifier)
    let windows = AXRead.elements(application, attribute: kAXWindowsAttribute as CFString)
    guard !windows.isEmpty else {
      throw WeChatReaderError.noWindows
    }

    return windows.map { window in
      let title = AXRead.string(window, attribute: kAXTitleAttribute as CFString).map {
        ProbeLabel(length: $0.count, digest: StableHash.hex($0))
      }
      let nodes = walk(
        window,
        maximumDepth: 16,
        maximumNodes: max(1, maximumNodesPerWindow)
      ).map { node in
        ProbeNode(
          depth: node.depth,
          role: node.role,
          frame: node.frame,
          childCount: node.childCount,
          labels: node.labels.map {
            ProbeLabel(length: $0.count, digest: StableHash.hex($0))
          }
        )
      }
      return ProbeWindow(title: title, nodes: nodes)
    }
  }

  private func selectTable(
    group: String,
    allowSingleGroupFallback: Bool
  ) throws -> TableCandidate {
    guard AXIsProcessTrusted() else {
      throw WeChatReaderError.accessibilityPermissionMissing
    }
    guard let runningApplication = runningWeChat() else {
      throw WeChatReaderError.weChatNotRunning
    }

    let application = AXUIElementCreateApplication(runningApplication.processIdentifier)
    let windows = AXRead.elements(application, attribute: kAXWindowsAttribute as CFString)
    guard !windows.isEmpty else {
      throw WeChatReaderError.noWindows
    }

    var candidates: [TableCandidate] = []
    for window in windows {
      candidates.append(
        contentsOf: tableCandidates(
          in: window,
          group: group,
          allowSingleGroupFallback: allowSingleGroupFallback
        ))
    }

    guard let selected = candidates.max(by: { $0.score < $1.score }) else {
      throw WeChatReaderError.groupWindowNotFound(group)
    }
    return selected
  }

  private func runningWeChat() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(
      withBundleIdentifier: Self.bundleIdentifier
    ).first
  }

  private func tableCandidates(
    in window: AXUIElement,
    group: String,
    allowSingleGroupFallback: Bool
  ) -> [TableCandidate] {
    let nodes = walk(window, maximumDepth: 14, maximumNodes: 8_000)
    let windowTitle =
      AXRead.string(window, attribute: kAXTitleAttribute as CFString)
      ?? AXRead.labels(window).first
      ?? "untitled"
    let windowTitleMatches = normalized(windowTitle).contains(normalized(group))
    var result: [TableCandidate] = []

    for tableNode in nodes where tableNode.role == (kAXTableRole as String) {
      let rows = messageRows(in: tableNode.element)
      guard !rows.isEmpty else { continue }

      let nearbyMatch = nodes.contains { node in
        node.labels.contains(where: { normalized($0) == normalized(group) })
          && isLikelyHeader(node.frame, above: tableNode.frame)
      }

      let confidence: SnapshotConfidence
      let confidenceScore: Double
      if windowTitleMatches {
        confidence = .exactWindowTitle
        confidenceScore = 2_000_000
      } else if nearbyMatch {
        confidence = .nearbyGroupLabel
        confidenceScore = 1_000_000
      } else if allowSingleGroupFallback {
        confidence = .singleGroupFallback
        confidenceScore = 0
      } else {
        continue
      }

      let horizontalScore = (tableNode.frame?.x ?? 0) * 100
      let sizeScore = (tableNode.frame?.width ?? 0) + Double(rows.count)
      result.append(
        TableCandidate(
          element: tableNode.element,
          windowTitle: windowTitle,
          tableFrame: tableNode.frame,
          confidence: confidence,
          score: confidenceScore + horizontalScore + sizeScore,
          rows: rows
        ))
    }
    return result
  }

  private func isLikelyHeader(_ labelFrame: ElementFrame?, above tableFrame: ElementFrame?) -> Bool
  {
    guard let labelFrame, let tableFrame else { return false }
    let labelMidX = labelFrame.x + labelFrame.width / 2
    let tableMinX = tableFrame.x - 40
    let tableMaxX = tableFrame.x + tableFrame.width + 40
    let verticalDistance = tableFrame.y - (labelFrame.y + labelFrame.height)
    return labelMidX >= tableMinX && labelMidX <= tableMaxX && verticalDistance >= -40
      && verticalDistance <= 220
  }

  private func messageRows(in table: AXUIElement) -> [RawMessageRow] {
    var rowElements = AXRead.elements(table, attribute: "AXRows" as CFString)
    if rowElements.isEmpty {
      rowElements = AXRead.children(table).filter {
        AXRead.role($0) == (kAXRowRole as String)
      }
    }

    return rowElements.compactMap { row in
      let nodes = walk(row, maximumDepth: 8, maximumNodes: 300)
      var labels: [String] = []
      var seen = Set<String>()
      for node in nodes {
        for label in node.labels {
          let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !value.isEmpty, !seen.contains(value) else { continue }
          seen.insert(value)
          labels.append(value)
        }
      }
      guard !labels.isEmpty else { return nil }
      return RawMessageRow(labels: labels, frame: AXRead.frame(row))
    }
  }

  private func walk(
    _ root: AXUIElement,
    maximumDepth: Int,
    maximumNodes: Int
  ) -> [AXNode] {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var index = 0
    var result: [AXNode] = []

    while index < queue.count, result.count < maximumNodes {
      let (element, depth) = queue[index]
      index += 1
      let children = AXRead.children(element)
      result.append(
        AXNode(
          element: element,
          role: AXRead.role(element),
          frame: AXRead.frame(element),
          labels: AXRead.labels(element),
          depth: depth,
          childCount: children.count
        ))
      if depth < maximumDepth {
        queue.append(contentsOf: children.map { ($0, depth + 1) })
      }
    }
    return result
  }

  private func normalized(_ value: String) -> String {
    value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
  }
}
