import Foundation

public enum VolcengineSeedStreamError: Error, Equatable, Sendable {
  case invalidFrame
  case invalidAudioData
  case provider(code: Int, message: String)
  case responseTooLarge(limitBytes: Int)
  case missingAudio
  case incomplete
}

extension VolcengineSeedStreamError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidFrame: return "火山流式语音返回了无法解析的数据帧"
    case .invalidAudioData: return "火山流式语音返回了无效音频"
    case .provider(let code, let message):
      let detail = message.isEmpty ? "未知错误" : message
      return "火山流式语音失败（\(code)）：\(detail)"
    case .responseTooLarge: return "火山流式语音响应过大"
    case .missingAudio: return "火山流式语音没有返回音频"
    case .incomplete: return "火山流式语音未正常结束"
    }
  }
}

/// Parses Volcengine V3 HTTP Chunked responses. Network chunks may split a JSON
/// line at any byte; only newline-delimited provider frames are decoded.
public struct VolcengineSeedStreamParser: Sendable {
  public static let completionCode = 20_000_000

  public private(set) var isComplete = false
  public private(set) var audioChunkCount = 0

  private let maximumResponseBytes: Int
  private var receivedByteCount = 0
  private var pending = Data()
  private var audio = Data()

  public init(maximumResponseBytes: Int = 4 * 1_024 * 1_024) {
    self.maximumResponseBytes = maximumResponseBytes
  }

  public mutating func consume(_ chunk: Data) throws -> [Data] {
    receivedByteCount += chunk.count
    guard receivedByteCount <= maximumResponseBytes else {
      throw VolcengineSeedStreamError.responseTooLarge(limitBytes: maximumResponseBytes)
    }
    pending.append(chunk)

    var decodedChunks: [Data] = []
    while let newline = pending.firstIndex(of: 0x0A) {
      let line = Data(pending[..<newline])
      pending.removeSubrange(...newline)
      if let decoded = try process(line) {
        decodedChunks.append(decoded)
      }
    }
    return decodedChunks
  }

  public mutating func finish() throws -> Data {
    if !pending.isEmpty {
      let finalLine = pending
      pending.removeAll(keepingCapacity: false)
      _ = try process(finalLine)
    }
    guard !audio.isEmpty else { throw VolcengineSeedStreamError.missingAudio }
    guard isComplete else { throw VolcengineSeedStreamError.incomplete }
    return audio
  }

  private mutating func process(_ rawLine: Data) throws -> Data? {
    guard let line = String(data: rawLine, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !line.isEmpty
    else { return nil }
    guard let data = line.data(using: .utf8),
      let frame = try? JSONDecoder().decode(Frame.self, from: data)
    else { throw VolcengineSeedStreamError.invalidFrame }

    let code = frame.code ?? 0
    if code == 0 {
      guard let encodedAudio = frame.data, !encodedAudio.isEmpty else { return nil }
      guard let decodedAudio = Data(base64Encoded: encodedAudio), !decodedAudio.isEmpty else {
        throw VolcengineSeedStreamError.invalidAudioData
      }
      audio.append(decodedAudio)
      audioChunkCount += 1
      return decodedAudio
    }
    if code == Self.completionCode {
      isComplete = true
      return nil
    }
    throw VolcengineSeedStreamError.provider(
      code: code,
      message: String((frame.message ?? "").prefix(240))
    )
  }

  private struct Frame: Decodable {
    let code: Int?
    let message: String?
    let data: String?
  }
}
