import CryptoKit
import Foundation

/// Why a channel ended. Every case maps to a failure reason code (FR-017).
enum RemoteChannelError: Error, Equatable, Sendable {
  /// The server could not open the hello (close code 4001): not the pinned server.
  case pinMismatch
  case unreachable
  /// The socket took no frame for `stallTimeout` while frames waited, or the server
  /// stopped answering.
  case timeout
  /// A frame out of sequence, one that did not open, a text message or bad JSON.
  case protocolError
  /// The server answered with an `error` message.
  case server(RemoteErrorCode)
  case closed

  var failureReason: RemoteFailureReason {
    switch self {
    case .pinMismatch: .pinMismatch
    case .unreachable, .closed: .unreachable
    case .timeout: .timeout
    case .protocolError: .protocolError
    case .server(let code): code.failureReason
    }
  }
}

/// The HPKE contexts and frame counters of one channel, without a socket
/// (`contracts/remote-channel.md`, "Framing and encryption"). Not thread-safe; the
/// owning `RemoteChannel` actor serializes it.
struct RemoteChannelCrypto {
  static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
  static let info = Data("localflow remote v1".utf8)
  static let magic = Data("LFR1".utf8)
  static let maximumMessageBytes = 70_000

  enum Kind: UInt8 {
    case control = 0x00
    case audio = 0x01
  }

  private var sender: HPKE.Sender
  private var recipient: HPKE.Recipient?
  private let replyKey: Curve25519.KeyAgreement.PrivateKey
  private var sendSequence: UInt64 = 0
  private var receiveSequence: UInt64 = 0
  let binding: Data
  private let s2cInfo: Data

  /// `s2cInfo` replaces the exported value only in tests that replay recorded server frames.
  init(
    serverKey: Curve25519.KeyAgreement.PublicKey,
    replyKey: Curve25519.KeyAgreement.PrivateKey = .init(), s2cInfo: Data? = nil
  ) throws {
    sender = try HPKE.Sender(recipientKey: serverKey, ciphersuite: Self.suite, info: Self.info)
    self.replyKey = replyKey
    binding = Self.data(
      try sender.exportSecret(context: Data("localflow v1 binding".utf8), outputByteCount: 32))
    self.s2cInfo =
      try s2cInfo
      ?? Self.data(
        sender.exportSecret(context: Data("localflow v1 s2c info".utf8), outputByteCount: 32))
  }

  var replyPublicKey: Data { replyKey.publicKey.rawRepresentation }

  /// `"LFR1" | enc | seq = 0 | Seal(aad = "LFR1" ‖ seq, hello JSON)`.
  mutating func helloFrame(_ hello: Data) throws -> Data {
    precondition(sendSequence == 0)
    let seq = Self.sequence(0)
    let sealed = try sender.seal(hello, authenticating: Self.magic + seq)
    sendSequence = 1
    return Self.magic + sender.encapsulatedKey + seq + sealed
  }

  /// `seq | Seal(aad = seq, kind ‖ payload)`.
  mutating func seal(_ kind: Kind, _ payload: Data) throws -> Data {
    precondition(sendSequence > 0)
    let seq = Self.sequence(sendSequence)
    let sealed = try sender.seal(Data([kind.rawValue]) + payload, authenticating: seq)
    sendSequence += 1
    let frame = seq + sealed
    guard frame.count <= Self.maximumMessageBytes else { throw RemoteChannelError.protocolError }
    return frame
  }

  /// Opens a server frame: the first carries `enc_s2c`. Returns the control JSON.
  mutating func open(_ frame: Data) throws -> Data {
    guard frame.count <= Self.maximumMessageBytes else { throw RemoteChannelError.protocolError }
    var body = frame
    if recipient == nil {
      guard body.count > 32 + 8 else { throw RemoteChannelError.protocolError }
      let enc = body.prefix(32)
      body = body.dropFirst(32)
      do {
        recipient = try HPKE.Recipient(
          privateKey: replyKey, ciphersuite: Self.suite, info: s2cInfo, encapsulatedKey: Data(enc))
      } catch { throw RemoteChannelError.protocolError }
    }
    guard body.count > 8, var recipient else { throw RemoteChannelError.protocolError }
    let seq = Data(body.prefix(8))
    guard seq == Self.sequence(receiveSequence) else { throw RemoteChannelError.protocolError }
    let plaintext: Data
    do {
      plaintext = try recipient.open(Data(body.dropFirst(8)), authenticating: seq)
    } catch { throw RemoteChannelError.protocolError }
    self.recipient = recipient
    receiveSequence += 1
    // The server sends control messages only.
    guard plaintext.first == Kind.control.rawValue,
      plaintext.count - 1 <= RemoteProtocol.maximumControlBytes
    else { throw RemoteChannelError.protocolError }
    return Data(plaintext.dropFirst())
  }

  static func sequence(_ value: UInt64) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
  }

  static func data(_ key: SymmetricKey) -> Data {
    key.withUnsafeBytes { Data($0) }
  }

  /// Little-endian Float32, the spool's own format.
  static func audioPayload(_ samples: ArraySlice<Float>) -> Data {
    var data = Data(capacity: samples.count * 4)
    for sample in samples {
      withUnsafeBytes(of: sample.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
  }
}

/// One encrypted channel over a WebSocket: hello, then sequential operations.
/// Frames are sealed in call order and sent by one loop, so sequence numbers go out
/// in order. With more than four frames unsent, a sender waits for the socket to take
/// one; if the socket takes none for `stallTimeout`, the channel fails with `timeout`.
actor RemoteChannel {
  static let maximumUnsentFrames = 4

  private let transport: any RemoteTransport
  private let stallTimeout: Duration
  private var crypto: RemoteChannelCrypto
  private var outbox: [Data] = []
  private var sending = false
  private var inFlight = false
  /// Frames the socket has taken; a waiting sender checks it for progress.
  private var sentFrames = 0
  private var waitingSenders: [CheckedContinuation<Void, Never>] = []
  private var failure: RemoteChannelError?
  private var closed = false

  init(transport: any RemoteTransport, serverKey: Data, stallTimeout: Duration = .seconds(15))
    throws
  {
    self.transport = transport
    self.stallTimeout = stallTimeout
    guard let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverKey) else {
      throw RemoteChannelError.pinMismatch
    }
    crypto = try RemoteChannelCrypto(serverKey: key)
  }

  /// The exporter value that binds signatures and the OIDC nonce to this channel.
  var binding: Data { crypto.binding }

  /// Sends the hello and waits for `ready`. A server `error` fails with `.server(code)`.
  func open(purpose: RemoteHelloPurpose, accessToken: String? = nil) async throws {
    let hello = RemoteHello(
      replyKey: crypto.replyPublicKey.base64URL, purpose: purpose, accessToken: accessToken)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let frame = try crypto.helloFrame(try encoder.encode(hello))
    try await enqueue(frame)
    switch try await receive() {
    case .ready: return
    case .error(_, let code): throw fail(.server(code))
    default: throw fail(.protocolError)
    }
  }

  /// Returns once the frame is queued; waits while more than four frames are unsent.
  func send(_ message: RemoteClientMessage) async throws {
    try await enqueue(try crypto.seal(.control, try message.encoded()))
  }

  /// At most 16,000 samples per frame. Waits like `send`.
  func sendAudio(_ samples: ArraySlice<Float>) async throws {
    guard (1...RemoteProtocol.maximumFrameSamples).contains(samples.count) else {
      throw fail(.protocolError)
    }
    try await enqueue(try crypto.seal(.audio, RemoteChannelCrypto.audioPayload(samples)))
  }

  /// The next server message. Transport and framing failures close the channel.
  func receive() async throws -> RemoteServerMessage {
    if let failure { throw failure }
    let message: RemoteTransportMessage
    do {
      message = try await transport.receive()
    } catch let error as RemoteTransportError {
      switch error {
      case .closed(let code) where code == 4001: throw fail(.pinMismatch)
      case .timeout: throw fail(.timeout)
      default: throw fail(.unreachable)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw fail(.unreachable)
    }
    if let failure { throw failure }
    guard case .binary(let frame) = message else { throw fail(.protocolError) }
    let json: Data
    do { json = try crypto.open(frame) } catch { throw fail(.protocolError) }
    do {
      return try RemoteServerMessage.decode(json)
    } catch RemoteProtocolError.unsupportedVersion {
      throw fail(.server(.unsupportedVersion))
    } catch {
      throw fail(.protocolError)
    }
  }

  func close() {
    guard !closed else { return }
    closed = true
    failure = failure ?? .closed
    outbox.removeAll()
    transport.close(code: 1000)
    wakeSenders()
  }

  /// Records the first failure and closes the socket; later calls see the same error.
  @discardableResult
  private func fail(_ error: RemoteChannelError) -> RemoteChannelError {
    if failure == nil { failure = error }
    if !closed {
      closed = true
      outbox.removeAll()
      transport.close(code: 1000)
    }
    wakeSenders()
    return failure ?? error
  }

  /// Queued frames plus the one the socket is still writing.
  private var unsentFrames: Int { outbox.count + (inFlight ? 1 : 0) }

  /// Queues the frame at once, so frames go out in seal order, then waits until at most
  /// four are unsent. A retry or reconnect flushes a whole recording through here, so
  /// the socket's pace, not a fixed count, limits it.
  private func enqueue(_ frame: Data) async throws {
    if let failure { throw failure }
    outbox.append(frame)
    if !sending {
      sending = true
      Task { await drain() }
    }
    while failure == nil, unsentFrames > Self.maximumUnsentFrames {
      let progress = sentFrames
      let watchdog = Task {
        guard (try? await Task.sleep(for: stallTimeout)) != nil else { return }
        self.stalled(since: progress)
      }
      await withCheckedContinuation { waitingSenders.append($0) }
      watchdog.cancel()
    }
    if let failure { throw failure }
  }

  private func stalled(since progress: Int) {
    guard sentFrames == progress, failure == nil else { return }
    fail(.timeout)
  }

  private func wakeSenders() {
    let waiting = waitingSenders
    waitingSenders = []
    for sender in waiting { sender.resume() }
  }

  private func drain() async {
    while !outbox.isEmpty, failure == nil {
      let frame = outbox.removeFirst()
      inFlight = true
      do { try await transport.send(frame) } catch {
        fail(.unreachable)
      }
      inFlight = false
      sentFrames += 1
      wakeSenders()
    }
    sending = false
  }
}

/// `URLSessionWebSocketTask`, binary only, with no cookies and no `Authorization` header.
final class URLSessionRemoteTransport: RemoteTransport, @unchecked Sendable {
  private let task: URLSessionWebSocketTask
  private let session: URLSession

  init(url: URL) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    // Idle time between received messages. Well above the server's 15 s ping, so a quiet
    // channel is not timed out just before the next ping arrives.
    configuration.timeoutIntervalForRequest = 45
    session = URLSession(configuration: configuration)
    task = session.webSocketTask(with: url)
    task.maximumMessageSize = RemoteChannelCrypto.maximumMessageBytes
    task.resume()
  }

  func send(_ data: Data) async throws {
    do { try await task.send(.data(data)) } catch { throw mapped(error) }
  }

  func receive() async throws -> RemoteTransportMessage {
    do {
      switch try await task.receive() {
      case .data(let data): return .binary(data)
      case .string: return .text
      @unknown default: return .text
      }
    } catch { throw mapped(error) }
  }

  func close(code: Int) {
    task.cancel(
      with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
    session.finishTasksAndInvalidate()
  }

  private func mapped(_ error: any Error) -> RemoteTransportError {
    if task.closeCode != .invalid { return .closed(code: task.closeCode.rawValue) }
    if (error as? URLError)?.code == .timedOut { return .timeout }
    return .unreachable
  }
}

struct URLSessionRemoteTransportOpener: RemoteTransportOpening {
  func open(_ url: URL) async throws -> any RemoteTransport {
    URLSessionRemoteTransport(url: url)
  }
}
