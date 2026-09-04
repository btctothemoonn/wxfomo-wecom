import Darwin
import Foundation
import Network

public enum AutomationSocketEndpoint: Equatable, Sendable {
  case disabled
  case applicationSupport
  case explicit(URL)
}

public enum AutomationEventBroadcasterConfigurationError: LocalizedError, Sendable {
  case invalidLimit(name: String)

  public var errorDescription: String? {
    switch self {
    case .invalidLimit(let name):
      return "Automation event broadcaster has an invalid \(name) limit."
    }
  }
}

public struct AutomationEventBroadcasterConfiguration: Equatable, Sendable {
  public let endpoint: AutomationSocketEndpoint
  public let maximumClients: Int
  public let maximumLineBytes: Int
  public let maximumBufferedBytesPerClient: Int

  public init(
    endpoint: AutomationSocketEndpoint = .disabled,
    maximumClients: Int = 8,
    maximumLineBytes: Int = AutomationEventNDJSONCodec.defaultMaximumLineBytes,
    maximumBufferedBytesPerClient: Int = 2_097_152
  ) throws {
    guard maximumClients > 0 else {
      throw AutomationEventBroadcasterConfigurationError.invalidLimit(name: "client")
    }
    guard maximumLineBytes > 0 else {
      throw AutomationEventBroadcasterConfigurationError.invalidLimit(name: "line byte")
    }
    // A queued frame includes the LF byte appended by the NDJSON codec.
    guard maximumLineBytes < Int.max,
      maximumBufferedBytesPerClient > maximumLineBytes
    else {
      throw AutomationEventBroadcasterConfigurationError.invalidLimit(
        name: "per-client buffer byte"
      )
    }
    self.endpoint = endpoint
    self.maximumClients = maximumClients
    self.maximumLineBytes = maximumLineBytes
    self.maximumBufferedBytesPerClient = maximumBufferedBytesPerClient
  }
}

public enum AutomationEventBroadcasterState: String, Equatable, Sendable {
  case disabled
  case stopped
  case listening
  case failed
}

public struct AutomationEventBroadcasterStatus: Equatable, Sendable {
  public let state: AutomationEventBroadcasterState
  public let streamID: String?
  public let connectedClients: Int
  public let bufferedBytes: Int
  public let acceptedConnections: UInt64
  public let disconnectedConnections: UInt64
  public let rejectedConnections: UInt64
  public let slowConsumerDisconnections: UInt64
  public let protocolViolationDisconnections: UInt64
  public let publishedEvents: UInt64
  public let eventsWithoutConsumers: UInt64
  public let droppedEvents: UInt64
  public let lastErrorCode: String?
}

public enum AutomationEventPublishDisposition: String, Equatable, Sendable {
  case disabled
  case notListening = "not_listening"
  case noConsumers = "no_consumers"
  case accepted
  case dropped
}

public struct AutomationEventPublishReport: Equatable, Sendable {
  public let disposition: AutomationEventPublishDisposition
  public let sequence: String?
  public let connectedClients: Int
  public let slowConsumersDisconnected: Int
}

public enum AutomationEventBroadcasterError: LocalizedError, Sendable {
  case invalidSocketPath(String)
  case socketPathOccupied
  case socketAlreadyActive
  case socketPathOwnedByAnotherUser
  case listenerFailed
  case socketOperation(operation: String, errno: Int32)

  public var errorDescription: String? {
    switch self {
    case .invalidSocketPath(let reason):
      return "Invalid automation socket path: \(reason)."
    case .socketPathOccupied:
      return "The automation socket path is occupied by a non-socket file."
    case .socketAlreadyActive:
      return "Another automation event broadcaster is already using this socket path."
    case .socketPathOwnedByAnotherUser:
      return "The existing automation socket is owned by another user."
    case .listenerFailed:
      return "The automation socket listener failed."
    case .socketOperation(let operation, let code):
      return "Automation socket operation \(operation) failed with errno \(code)."
    }
  }
}

private final class AutomationSocketLock: @unchecked Sendable {
  let descriptor: Int32
  private var isClosed = false

  init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    Darwin.close(descriptor)
  }

  deinit {
    close()
  }
}

public actor AutomationEventBroadcaster {
  private struct SocketIdentity {
    let device: dev_t
    let inode: ino_t
  }

  private struct Client {
    let id: UInt64
    let connection: NWConnection
    var frames: [Data] = []
    var headIndex = 0
    var bufferedBytes = 0
    var isReady = false
    var isSending = false
  }

  private enum ClientDisconnectReason {
    case peerClosed
    case writeFailure
    case slowConsumer
    case protocolViolation
    case shutdown
  }

  private let configuration: AutomationEventBroadcasterConfiguration
  private let codec: AutomationEventNDJSONCodec
  private let ioQueue = DispatchQueue(label: "dev.wxfomo.automation-event-broadcaster")

  private var state: AutomationEventBroadcasterState = .stopped
  private var listener: NWListener?
  private var listenerToken: UInt64 = 0
  private var startContinuation: CheckedContinuation<Void, Error>?
  private var socketLock: AutomationSocketLock?
  private var socketURL: URL?
  private var socketIdentity: SocketIdentity?
  private var clients: [UInt64: Client] = [:]
  private var streamID = UUID()
  private var nextSequence: Int64 = 0
  private var nextClientID: UInt64 = 0

  private var acceptedConnections: UInt64 = 0
  private var disconnectedConnections: UInt64 = 0
  private var rejectedConnections: UInt64 = 0
  private var slowConsumerDisconnections: UInt64 = 0
  private var protocolViolationDisconnections: UInt64 = 0
  private var publishedEvents: UInt64 = 0
  private var eventsWithoutConsumers: UInt64 = 0
  private var droppedEvents: UInt64 = 0
  private var lastErrorCode: String?

  public init(configuration: AutomationEventBroadcasterConfiguration) {
    self.configuration = configuration
    self.codec = AutomationEventNDJSONCodec(maximumLineBytes: configuration.maximumLineBytes)
    if configuration.endpoint == .disabled {
      self.state = .disabled
    }
  }

  public func start() async throws {
    guard listener == nil else {
      if state == .listening { return }
      throw AutomationEventBroadcasterError.listenerFailed
    }
    guard configuration.endpoint != .disabled else {
      state = .disabled
      return
    }

    let resolvedURL: URL
    do {
      resolvedURL = try resolveSocketURL(configuration.endpoint)
      try validateSocketPath(resolvedURL.path)
      socketLock = try acquireSocketLock(atPath: resolvedURL.path + ".lock")
      try removeOwnedStaleSocketIfPresent(atPath: resolvedURL.path)

      let parameters = NWParameters.tcp
      parameters.requiredLocalEndpoint = .unix(path: resolvedURL.path)
      let newListener = try NWListener(using: parameters)

      listenerToken &+= 1
      let token = listenerToken
      newListener.newConnectionHandler = { [weak self] connection in
        Task {
          await self?.accept(connection, listenerToken: token)
        }
      }
      newListener.stateUpdateHandler = { [weak self] listenerState in
        switch listenerState {
        case .ready:
          Task { await self?.listenerBecameReady(token: token) }
        case .failed:
          Task { await self?.listenerFailed(token: token) }
        case .cancelled:
          Task { await self?.listenerCancelled(token: token) }
        case .setup, .waiting:
          break
        @unknown default:
          Task { await self?.listenerFailed(token: token) }
        }
      }

      listener = newListener
      socketURL = resolvedURL
      socketIdentity = nil
      streamID = UUID()
      nextSequence = 0
      lastErrorCode = nil

      try await withCheckedThrowingContinuation { continuation in
        startContinuation = continuation
        newListener.start(queue: ioQueue)
      }
    } catch {
      if listener == nil {
        cleanupSocketPath()
        releaseSocketLock()
        socketURL = nil
      }
      if error is CancellationError, state == .stopped {
        throw error
      }
      state = .failed
      lastErrorCode = errorCode(for: error)
      throw error
    }
  }

  public func stop() {
    let pendingStart = startContinuation
    startContinuation = nil

    let clientIDs = Array(clients.keys)
    for clientID in clientIDs {
      disconnect(clientID, reason: .shutdown)
    }

    let currentListener = listener
    listener = nil
    currentListener?.stateUpdateHandler = nil
    currentListener?.newConnectionHandler = nil
    currentListener?.cancel()
    cleanupSocketPath()
    releaseSocketLock()
    socketURL = nil
    socketIdentity = nil
    state = configuration.endpoint == .disabled ? .disabled : .stopped
    pendingStart?.resume(throwing: CancellationError())
  }

  public func publish(_ event: MessageEvent, emittedAt: Date = Date()) -> AutomationEventPublishReport {
    guard configuration.endpoint != .disabled else {
      return report(disposition: .disabled, sequence: nil, slowConsumersDisconnected: 0)
    }
    guard state == .listening, listener != nil else {
      return report(disposition: .notListening, sequence: nil, slowConsumersDisconnected: 0)
    }

    if nextSequence == Int64.max {
      streamID = UUID()
      nextSequence = 0
    }
    nextSequence += 1
    let sequence = nextSequence

    let frame: Data
    do {
      frame = try codec.encodeMessage(
        event,
        streamID: streamID,
        sequence: sequence,
        emittedAt: emittedAt
      )
    } catch {
      droppedEvents &+= 1
      lastErrorCode = errorCode(for: error)
      return report(
        disposition: .dropped,
        sequence: String(sequence),
        slowConsumersDisconnected: 0
      )
    }

    publishedEvents &+= 1
    guard !clients.isEmpty else {
      eventsWithoutConsumers &+= 1
      return report(
        disposition: .noConsumers,
        sequence: String(sequence),
        slowConsumersDisconnected: 0
      )
    }

    var disconnectedSlowConsumers = 0
    var recipientCount = 0
    for clientID in Array(clients.keys) {
      guard var client = clients[clientID] else { continue }
      guard client.bufferedBytes <= configuration.maximumBufferedBytesPerClient,
        frame.count <= configuration.maximumBufferedBytesPerClient - client.bufferedBytes
      else {
        disconnect(clientID, reason: .slowConsumer)
        disconnectedSlowConsumers += 1
        continue
      }

      client.frames.append(frame)
      client.bufferedBytes += frame.count
      clients[clientID] = client
      recipientCount += 1
      pump(clientID)
    }

    guard recipientCount > 0 else {
      eventsWithoutConsumers &+= 1
      if disconnectedSlowConsumers > 0 { droppedEvents &+= 1 }
      return report(
        disposition: .noConsumers,
        sequence: String(sequence),
        slowConsumersDisconnected: disconnectedSlowConsumers
      )
    }

    return report(
      disposition: .accepted,
      sequence: String(sequence),
      slowConsumersDisconnected: disconnectedSlowConsumers
    )
  }

  public func status() -> AutomationEventBroadcasterStatus {
    AutomationEventBroadcasterStatus(
      state: state,
      streamID: state == .listening ? streamID.uuidString.lowercased() : nil,
      connectedClients: clients.count,
      bufferedBytes: clients.values.reduce(0) { $0 + $1.bufferedBytes },
      acceptedConnections: acceptedConnections,
      disconnectedConnections: disconnectedConnections,
      rejectedConnections: rejectedConnections,
      slowConsumerDisconnections: slowConsumerDisconnections,
      protocolViolationDisconnections: protocolViolationDisconnections,
      publishedEvents: publishedEvents,
      eventsWithoutConsumers: eventsWithoutConsumers,
      droppedEvents: droppedEvents,
      lastErrorCode: lastErrorCode
    )
  }

  private func report(
    disposition: AutomationEventPublishDisposition,
    sequence: String?,
    slowConsumersDisconnected: Int
  ) -> AutomationEventPublishReport {
    AutomationEventPublishReport(
      disposition: disposition,
      sequence: sequence,
      connectedClients: clients.count,
      slowConsumersDisconnected: slowConsumersDisconnected
    )
  }

  private func listenerBecameReady(token: UInt64) {
    guard token == listenerToken, listener != nil, let socketURL else { return }
    do {
      guard Darwin.chmod(socketURL.path, S_IRUSR | S_IWUSR) == 0 else {
        throw socketError("chmod")
      }
      socketIdentity = try verifiedSocketIdentity(atPath: socketURL.path)
      state = .listening
      let continuation = startContinuation
      startContinuation = nil
      continuation?.resume()
    } catch {
      failListener(token: token, error: error)
    }
  }

  private func listenerFailed(token: UInt64) {
    failListener(token: token, error: AutomationEventBroadcasterError.listenerFailed)
  }

  private func listenerCancelled(token: UInt64) {
    guard token == listenerToken, listener != nil else { return }
    failListener(token: token, error: CancellationError())
  }

  private func failListener(token: UInt64, error: Error) {
    guard token == listenerToken, let currentListener = listener else { return }
    listener = nil
    currentListener.stateUpdateHandler = nil
    currentListener.newConnectionHandler = nil
    currentListener.cancel()

    let clientIDs = Array(clients.keys)
    for clientID in clientIDs {
      disconnect(clientID, reason: .shutdown)
    }

    cleanupSocketPath()
    releaseSocketLock()
    socketURL = nil
    socketIdentity = nil
    state = .failed
    lastErrorCode = errorCode(for: error)
    let continuation = startContinuation
    startContinuation = nil
    continuation?.resume(throwing: error)
  }

  private func accept(_ connection: NWConnection, listenerToken token: UInt64) {
    guard token == listenerToken, state == .listening, listener != nil else {
      connection.cancel()
      return
    }
    guard clients.count < configuration.maximumClients else {
      rejectedConnections &+= 1
      connection.cancel()
      return
    }

    nextClientID &+= 1
    let clientID = nextClientID
    connection.stateUpdateHandler = { [weak self] connectionState in
      switch connectionState {
      case .ready:
        Task { await self?.clientBecameReady(clientID) }
      case .failed, .cancelled:
        Task { await self?.clientEnded(clientID) }
      case .setup, .preparing, .waiting:
        break
      @unknown default:
        Task { await self?.clientEnded(clientID) }
      }
    }
    clients[clientID] = Client(id: clientID, connection: connection)
    acceptedConnections &+= 1
    connection.start(queue: ioQueue)
  }

  private func clientBecameReady(_ clientID: UInt64) {
    guard var client = clients[clientID] else { return }
    client.isReady = true
    clients[clientID] = client
    receiveFromClient(clientID)
    pump(clientID)
  }

  private func clientEnded(_ clientID: UInt64) {
    disconnect(clientID, reason: .peerClosed)
  }

  private func receiveFromClient(_ clientID: UInt64) {
    guard let client = clients[clientID], client.isReady else { return }
    client.connection.receive(
      minimumIncompleteLength: 1,
      maximumLength: 1
    ) { [weak self] data, _, isComplete, error in
      let receivedData = !(data?.isEmpty ?? true)
      let connectionEnded = isComplete || error != nil
      Task {
        await self?.clientReceiveCompleted(
          clientID,
          receivedData: receivedData,
          connectionEnded: connectionEnded
        )
      }
    }
  }

  private func clientReceiveCompleted(
    _ clientID: UInt64,
    receivedData: Bool,
    connectionEnded: Bool
  ) {
    guard clients[clientID] != nil else { return }
    if receivedData {
      // This transport intentionally has no client-to-server command channel.
      disconnect(clientID, reason: .protocolViolation)
    } else if connectionEnded {
      disconnect(clientID, reason: .peerClosed)
    } else {
      receiveFromClient(clientID)
    }
  }

  private func pump(_ clientID: UInt64) {
    guard var client = clients[clientID],
      client.isReady,
      !client.isSending,
      client.frames.indices.contains(client.headIndex)
    else { return }

    let frame = client.frames[client.headIndex]
    client.isSending = true
    clients[clientID] = client
    client.connection.send(content: frame, completion: .contentProcessed { [weak self] error in
      Task {
        await self?.sendCompleted(clientID, failed: error != nil)
      }
    })
  }

  private func sendCompleted(_ clientID: UInt64, failed: Bool) {
    guard var client = clients[clientID], client.isSending else { return }
    if failed {
      disconnect(clientID, reason: .writeFailure)
      return
    }
    guard client.frames.indices.contains(client.headIndex) else {
      disconnect(clientID, reason: .writeFailure)
      return
    }

    client.bufferedBytes -= client.frames[client.headIndex].count
    client.headIndex += 1
    client.isSending = false
    if client.headIndex >= 64, client.headIndex * 2 >= client.frames.count {
      client.frames.removeFirst(client.headIndex)
      client.headIndex = 0
    }
    clients[clientID] = client
    pump(clientID)
  }

  private func disconnect(_ clientID: UInt64, reason: ClientDisconnectReason) {
    guard let client = clients.removeValue(forKey: clientID) else { return }
    client.connection.stateUpdateHandler = nil
    client.connection.cancel()
    disconnectedConnections &+= 1

    switch reason {
    case .slowConsumer:
      slowConsumerDisconnections &+= 1
    case .protocolViolation:
      protocolViolationDisconnections &+= 1
    case .peerClosed, .writeFailure, .shutdown:
      break
    }
  }

  private func resolveSocketURL(_ endpoint: AutomationSocketEndpoint) throws -> URL {
    switch endpoint {
    case .disabled:
      throw AutomationEventBroadcasterError.invalidSocketPath("the endpoint is disabled")
    case .applicationSupport:
      let root = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let applicationDirectory = root.appendingPathComponent("wxFomo", isDirectory: true)
      try ensurePrivateDirectory(applicationDirectory)
      let directory = applicationDirectory.appendingPathComponent(
        "automation",
        isDirectory: true
      )
      try ensurePrivateDirectory(directory)
      return directory.appendingPathComponent("events.sock", isDirectory: false)
    case .explicit(let url):
      guard url.isFileURL, url.path.hasPrefix("/") else {
        throw AutomationEventBroadcasterError.invalidSocketPath(
          "an explicit endpoint must be an absolute file URL"
        )
      }
      let standardizedURL = url.standardizedFileURL
      try validatePrivateDirectory(standardizedURL.deletingLastPathComponent())
      return standardizedURL
    }
  }

  private func validateSocketPath(_ path: String) throws {
    guard !path.utf8.contains(0) else {
      throw AutomationEventBroadcasterError.invalidSocketPath("the path contains a NUL byte")
    }
    let maximumBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    guard path.utf8CString.count <= maximumBytes else {
      throw AutomationEventBroadcasterError.invalidSocketPath(
        "the UTF-8 path exceeds the Unix socket limit"
      )
    }
  }

  private func ensurePrivateDirectory(_ url: URL) throws {
    if Darwin.mkdir(url.path, S_IRWXU) != 0, errno != EEXIST {
      throw socketError("mkdir")
    }
    try validateOwnedDirectory(url)
    guard Darwin.chmod(url.path, S_IRWXU) == 0 else {
      throw socketError("chmod_directory")
    }
    try validatePrivateDirectory(url)
  }

  private func validateOwnedDirectory(_ url: URL) throws {
    var fileInfo = stat()
    guard Darwin.lstat(url.path, &fileInfo) == 0 else {
      throw socketError("lstat_directory")
    }
    guard fileInfo.st_uid == Darwin.geteuid(), fileInfo.st_mode & S_IFMT == S_IFDIR else {
      throw AutomationEventBroadcasterError.invalidSocketPath(
        "the socket parent must be a current-user directory, not a symbolic link"
      )
    }
  }

  private func validatePrivateDirectory(_ url: URL) throws {
    try validateOwnedDirectory(url)
    var fileInfo = stat()
    guard Darwin.lstat(url.path, &fileInfo) == 0 else {
      throw socketError("lstat_directory_permissions")
    }
    guard fileInfo.st_mode & 0o077 == 0 else {
      throw AutomationEventBroadcasterError.invalidSocketPath(
        "the socket parent directory must not be accessible by group or other users"
      )
    }
  }

  private func acquireSocketLock(atPath path: String) throws -> AutomationSocketLock {
    let descriptor = Darwin.open(
      path,
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
      if errno == EWOULDBLOCK {
        throw AutomationEventBroadcasterError.socketAlreadyActive
      }
      throw socketError("open_lock")
    }

    var fileInfo = stat()
    guard Darwin.fstat(descriptor, &fileInfo) == 0 else {
      let savedErrno = errno
      Darwin.close(descriptor)
      throw AutomationEventBroadcasterError.socketOperation(
        operation: "fstat_lock",
        errno: savedErrno
      )
    }
    guard fileInfo.st_uid == Darwin.geteuid(),
      fileInfo.st_mode & S_IFMT == S_IFREG,
      fileInfo.st_nlink == 1
    else {
      Darwin.close(descriptor)
      throw AutomationEventBroadcasterError.invalidSocketPath(
        "the socket lock must be a current-user regular file with one link"
      )
    }
    guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
      let savedErrno = errno
      Darwin.close(descriptor)
      throw AutomationEventBroadcasterError.socketOperation(
        operation: "chmod_lock",
        errno: savedErrno
      )
    }
    return AutomationSocketLock(descriptor: descriptor)
  }

  private func releaseSocketLock() {
    socketLock?.close()
    socketLock = nil
  }

  private func removeOwnedStaleSocketIfPresent(atPath path: String) throws {
    var fileInfo = stat()
    guard Darwin.lstat(path, &fileInfo) == 0 else {
      if errno == ENOENT { return }
      throw socketError("lstat_existing")
    }
    guard fileInfo.st_uid == Darwin.geteuid() else {
      throw AutomationEventBroadcasterError.socketPathOwnedByAnotherUser
    }
    guard fileInfo.st_mode & S_IFMT == S_IFSOCK else {
      throw AutomationEventBroadcasterError.socketPathOccupied
    }
    guard Darwin.unlink(path) == 0 else {
      throw socketError("unlink_stale")
    }
  }

  private func verifiedSocketIdentity(atPath path: String) throws -> SocketIdentity {
    var fileInfo = stat()
    guard Darwin.lstat(path, &fileInfo) == 0 else {
      throw socketError("lstat_bound")
    }
    guard fileInfo.st_uid == Darwin.geteuid(),
      fileInfo.st_mode & S_IFMT == S_IFSOCK,
      fileInfo.st_mode & 0o777 == 0o600
    else {
      throw AutomationEventBroadcasterError.invalidSocketPath(
        "the bound endpoint did not verify as a current-user 0600 socket"
      )
    }
    return SocketIdentity(device: fileInfo.st_dev, inode: fileInfo.st_ino)
  }

  private func cleanupSocketPath() {
    guard let socketURL else { return }
    var fileInfo = stat()
    guard Darwin.lstat(socketURL.path, &fileInfo) == 0 else { return }
    if let socketIdentity {
      guard fileInfo.st_dev == socketIdentity.device,
        fileInfo.st_ino == socketIdentity.inode
      else { return }
    } else {
      guard fileInfo.st_uid == Darwin.geteuid(), fileInfo.st_mode & S_IFMT == S_IFSOCK else {
        return
      }
    }
    _ = Darwin.unlink(socketURL.path)
  }

  private func socketError(_ operation: String) -> AutomationEventBroadcasterError {
    AutomationEventBroadcasterError.socketOperation(operation: operation, errno: errno)
  }

  private func errorCode(for error: Error) -> String {
    switch error {
    case AutomationEventEncodingError.invalidSequence:
      return "invalid_sequence"
    case AutomationEventEncodingError.frameTooLarge:
      return "frame_too_large"
    case AutomationEventEncodingError.unexpectedLineBreak:
      return "invalid_ndjson"
    case AutomationEventBroadcasterError.invalidSocketPath:
      return "invalid_socket_path"
    case AutomationEventBroadcasterError.socketPathOccupied:
      return "socket_path_occupied"
    case AutomationEventBroadcasterError.socketAlreadyActive:
      return "socket_already_active"
    case AutomationEventBroadcasterError.socketPathOwnedByAnotherUser:
      return "socket_path_wrong_owner"
    case AutomationEventBroadcasterError.listenerFailed:
      return "listener_failed"
    case AutomationEventBroadcasterError.socketOperation(let operation, _):
      return "socket_\(operation)_failed"
    case is CancellationError:
      return "cancelled"
    default:
      return "automation_bridge_error"
    }
  }
}
