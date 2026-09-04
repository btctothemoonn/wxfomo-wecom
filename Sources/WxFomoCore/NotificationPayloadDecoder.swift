import Foundation

public struct NotificationPayloadDecoder: Sendable {
  public init() {}

  public func decode(
    data: Data,
    rowID: Int64,
    deliveredAt: Date,
    uuid: String?,
    sourceIdentity: String? = nil
  ) -> NotificationRecord? {
    guard
      let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let dictionary = root as? [String: Any],
      let request = dictionary["req"] as? [String: Any]
    else {
      return nil
    }

    return NotificationRecord(
      rowID: rowID,
      uuid: uuid,
      deliveredAt: deliveredAt,
      title: text(request["titl"]),
      subtitle: text(request["subt"]),
      body: text(request["body"]),
      identifier: text(request["iden"]),
      attachments: attachments(from: request),
      conversationType: conversationType(from: request),
      sourceIdentity: sourceIdentity
    )
  }

  private func conversationType(from request: [String: Any]) -> Int? {
    guard let archive = request["usda"] as? Data,
      let decoded = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(archive),
      let userData = decoded as? [String: Any],
      let value = userData["ct"] as? NSNumber
    else {
      return nil
    }
    return value.intValue
  }

  private func attachments(from request: [String: Any]) -> [MessageAttachment] {
    let containers = request.compactMap { key, value -> Any? in
      let normalized = key.lowercased()
      return normalized == "atta" || normalized.contains("attach") ? value : nil
    }
    var results: [MessageAttachment] = []
    for container in containers {
      collectAttachments(from: container, metadata: [:], into: &results)
    }

    var seen = Set<String>()
    return results.filter { attachment in
      seen.insert(attachment.fileURL.standardizedFileURL.path).inserted
    }
  }

  private func collectAttachments(
    from value: Any,
    metadata: [String: Any],
    into results: inout [MessageAttachment]
  ) {
    if let dictionary = value as? [String: Any] {
      let normalized = Dictionary(uniqueKeysWithValues: dictionary.map {
        ($0.key.lowercased(), $0.value)
      })
      let identifier = firstText(in: normalized, keys: ["identifier", "id"])
      let typeHint = firstText(
        in: normalized,
        keys: ["type", "uti", "typehint", "uniformtypeidentifier"]
      )
      let resolvedIdentifier = identifier ?? firstText(in: metadata, keys: ["identifier"])
      let resolvedTypeHint = typeHint ?? firstText(in: metadata, keys: ["type"])
      var combinedMetadata = metadata
      if let resolvedIdentifier = resolvedIdentifier {
        combinedMetadata["identifier"] = resolvedIdentifier
      }
      if let resolvedTypeHint = resolvedTypeHint {
        combinedMetadata["type"] = resolvedTypeHint
      }

      for key in ["url", "fileurl", "path", "filepath", "localurl"] {
        guard let candidate = normalized[key], let url = fileURL(from: candidate) else { continue }
        results.append(
          MessageAttachment(
            identifier: resolvedIdentifier,
            fileURL: url,
            typeHint: resolvedTypeHint,
            kind: attachmentKind(url: url, typeHint: resolvedTypeHint)
          ))
      }

      for (key, child) in normalized where
        !["url", "fileurl", "path", "filepath", "localurl"].contains(key)
      {
        collectAttachments(from: child, metadata: combinedMetadata, into: &results)
      }
      return
    }
    if let values = value as? [Any] {
      for child in values {
        collectAttachments(from: child, metadata: metadata, into: &results)
      }
      return
    }
    if let url = fileURL(from: value) {
      let typeHint = firstText(in: metadata, keys: ["type"])
      results.append(
        MessageAttachment(
          identifier: firstText(in: metadata, keys: ["identifier"]),
          fileURL: url,
          typeHint: typeHint,
          kind: attachmentKind(url: url, typeHint: typeHint)
        ))
    }
  }

  private func fileURL(from value: Any) -> URL? {
    if let url = value as? URL, url.isFileURL { return url.standardizedFileURL }
    guard let raw = value as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("/") {
      return URL(fileURLWithPath: trimmed).standardizedFileURL
    }
    guard let url = URL(string: trimmed), url.isFileURL else { return nil }
    return url.standardizedFileURL
  }

  private func firstText(in dictionary: [String: Any], keys: [String]) -> String? {
    for key in keys {
      guard let value = dictionary[key] as? String else { continue }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    return nil
  }

  private func attachmentKind(url: URL, typeHint: String?) -> MessageAttachmentKind {
    let hint = (typeHint ?? "").lowercased()
    if hint.contains("image") { return .image }
    if hint.contains("video") || hint.contains("movie") { return .video }
    if hint.contains("audio") { return .audio }

    switch url.pathExtension.lowercased() {
    case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp":
      return .image
    case "mov", "mp4", "m4v", "avi", "webm":
      return .video
    case "mp3", "m4a", "aac", "wav", "caf", "flac", "ogg":
      return .audio
    case "":
      return .unknown
    default:
      return .file
    }
  }

  private func text(_ value: Any?) -> String {
    if let value = value as? String {
      return clean(value)
    }
    if let values = value as? [Any] {
      // Localized notifications may store [formatKey, tableName, arguments].
      let strings = flattenStrings(values)
      return clean(strings.last ?? "")
    }
    return ""
  }

  private func flattenStrings(_ value: Any) -> [String] {
    if let string = value as? String { return [string] }
    if let array = value as? [Any] { return array.flatMap(flattenStrings) }
    if let dictionary = value as? [String: Any] {
      var result: [String] = []
      for key in dictionary.keys.sorted() {
        if let item = dictionary[key] {
          result.append(contentsOf: flattenStrings(item))
        }
      }
      return result
    }
    return []
  }

  private func clean(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\t", with: " ")
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
