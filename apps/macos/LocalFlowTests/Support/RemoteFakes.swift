import CryptoKit
import Foundation

@testable import LocalFlow

/// Feature 014 fakes: a WebSocket whose other end is a scripted flowd that speaks the
/// real channel crypto, an in-memory Keychain, software device keys, a scripted
/// identity provider and a manual monotonic clock.

func remoteFixturesURL() -> URL {
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("fixtures/remote", isDirectory: true)
}

extension Data {
  init(hex: String) {
    var bytes = [UInt8]()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      bytes.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
    self.init(bytes)
  }
}

/// What the fake server saw from the client, already decrypted.
enum FakeClientEvent: @unchecked Sendable {
  case hello(purpose: String, accessToken: String?, binding: Data)
  case control([String: Any])
  case audio([Float])
  /// Feature 018: a kind-0x02 frame of little-endian `Int16` samples.
  case s16([Int16])

  var type: String? {
    if case .control(let object) = self { return object["type"] as? String }
    return nil
  }
  var op: Int? {
    if case .control(let object) = self { return object["op"] as? Int }
    return nil
  }
}

/// What the fake server sends back.
enum FakeServerReply: @unchecked Sendable {
  case message([String: Any])
  /// Close the socket with a WebSocket close code (4001 for an unopenable hello).
  case close(Int)
  /// Bytes sent as they are, for sequence and corruption tests.
  case raw(Data)
  case text
  /// A frame sealed correctly but with the given sequence number in clear.
  case wrongSequence([String: Any], UInt64)
}

/// flowd's side of the channel, with the real HPKE construction.
final class FakeRemoteServer: @unchecked Sendable {
  static let serverKey = Curve25519.KeyAgreement.PrivateKey()
  let privateKey: Curve25519.KeyAgreement.PrivateKey
  private var recipient: HPKE.Recipient?
  private var sender: HPKE.Sender?
  private var sentFirst = false
  private var sendSequence: UInt64 = 0
  private var receiveSequence: UInt64 = 0
  private(set) var binding = Data()

  init(privateKey: Curve25519.KeyAgreement.PrivateKey = FakeRemoteServer.serverKey) {
    self.privateKey = privateKey
  }

  var publicKey: Data { privateKey.publicKey.rawRepresentation }

  /// Nil when the frame does not open: the real server closes with 4001 or no reply.
  func receive(_ frame: Data) -> FakeClientEvent? {
    if recipient == nil {
      guard frame.count > 44, frame.prefix(4) == Data("LFR1".utf8) else { return nil }
      let enc = frame.subdata(in: 4..<36)
      let seq = frame.subdata(in: 36..<44)
      guard
        var recipient = try? HPKE.Recipient(
          privateKey: privateKey, ciphersuite: RemoteChannelCrypto.suite,
          info: RemoteChannelCrypto.info, encapsulatedKey: enc),
        seq == RemoteChannelCrypto.sequence(0),
        let hello = try? recipient.open(
          frame.subdata(in: 44..<frame.count), authenticating: frame.prefix(4) + seq),
        let object = try? JSONSerialization.jsonObject(with: hello) as? [String: Any],
        let replyText = object["reply_key"] as? String, let reply = Data(base64URL: replyText),
        let replyKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: reply),
        let bindingKey = try? recipient.exportSecret(
          context: Data("localflow v1 binding".utf8), outputByteCount: 32),
        let infoKey = try? recipient.exportSecret(
          context: Data("localflow v1 s2c info".utf8), outputByteCount: 32),
        let sender = try? HPKE.Sender(
          recipientKey: replyKey, ciphersuite: RemoteChannelCrypto.suite,
          info: RemoteChannelCrypto.data(infoKey))
      else { return nil }
      self.recipient = recipient
      self.sender = sender
      receiveSequence = 1
      binding = RemoteChannelCrypto.data(bindingKey)
      return .hello(
        purpose: object["purpose"] as? String ?? "", accessToken: object["access_token"] as? String,
        binding: binding)
    }
    guard frame.count > 8, var recipient else { return nil }
    let seq = frame.prefix(8)
    guard seq == RemoteChannelCrypto.sequence(receiveSequence),
      let plaintext = try? recipient.open(frame.dropFirst(8), authenticating: seq)
    else { return nil }
    self.recipient = recipient
    receiveSequence += 1
    let payload = plaintext.dropFirst()
    switch plaintext.first {
    case 0x00:
      guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
        return nil
      }
      return .control(object)
    case 0x01:
      let samples = stride(from: payload.startIndex, to: payload.endIndex, by: 4).map { start in
        Float(
          bitPattern: payload[start..<start + 4].withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
          }.littleEndian)
      }
      return .audio(samples)
    case 0x02:
      let samples = stride(from: payload.startIndex, to: payload.endIndex, by: 2).map { start in
        Int16(
          littleEndian: payload[start..<start + 2].withUnsafeBytes {
            $0.loadUnaligned(as: Int16.self)
          }
        )
      }
      return .s16(samples)
    default: return nil
    }
  }

  func seal(_ object: [String: Any], sequence override: UInt64? = nil) -> Data {
    var message = object
    if message["schema_version"] == nil { message["schema_version"] = 1 }
    let json = try! JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
    let seq = RemoteChannelCrypto.sequence(override ?? sendSequence)
    let sealed = try! sender!.seal(Data([0x00]) + json, authenticating: seq)
    sendSequence += 1
    var frame = Data()
    if !sentFirst {
      frame += sender!.encapsulatedKey
      sentFirst = true
    }
    return frame + seq + sealed
  }
}

/// A WebSocket whose far end is `FakeRemoteServer` driven by `handler`. Each client
/// event produces zero or more replies, delivered in order.
final class FakeRemoteTransport: RemoteTransport, @unchecked Sendable {
  let server: FakeRemoteServer
  private let lock = NSLock()
  private var handler: (FakeClientEvent) -> [FakeServerReply]
  private var inbox: [Result<RemoteTransportMessage, RemoteTransportError>] = []
  private var waiters: [CheckedContinuation<RemoteTransportMessage, any Error>] = []
  private var events: [FakeClientEvent] = []
  private(set) var closedWith: Int?
  /// While true, `send` suspends until `releaseSends()`; frames count as unsent.
  var holdSends = false
  private var heldSends: [CheckedContinuation<Void, Never>] = []
  /// Each `send` takes this long, like a real socket on a slow uplink.
  var sendDelay: Duration?

  init(
    server: FakeRemoteServer = FakeRemoteServer(),
    handler: @escaping (FakeClientEvent) -> [FakeServerReply] = { _ in [] }
  ) {
    self.server = server
    self.handler = handler
  }

  func setHandler(_ handler: @escaping (FakeClientEvent) -> [FakeServerReply]) {
    lock.withLock { self.handler = handler }
  }

  var receivedEvents: [FakeClientEvent] { lock.withLock { events } }
  var controlTypes: [String] { receivedEvents.compactMap(\.type) }
  var s16Samples: [Int16] {
    receivedEvents.flatMap { event -> [Int16] in
      if case .s16(let samples) = event { return samples }
      return []
    }
  }
  var audioSamples: [Float] {
    receivedEvents.flatMap { event -> [Float] in
      if case .audio(let samples) = event { return samples }
      return []
    }
  }

  func send(_ data: Data) async throws {
    if let delay = lock.withLock({ sendDelay }) { try? await Task.sleep(for: delay) }
    let hold = lock.withLock { holdSends }
    if hold {
      await withCheckedContinuation { continuation in
        lock.withLock { heldSends.append(continuation) }
      }
    }
    let (closed, event, handler) = lock.withLock {
      (closedWith, server.receive(data), self.handler)
    }
    if closed != nil { throw RemoteTransportError.closed(code: closed!) }
    guard let event else {
      // The server closes without a reply; an unopenable hello gets 4001.
      push(.failure(.closed(code: events.isEmpty ? 4001 : 1002)))
      return
    }
    lock.withLock { events.append(event) }
    for reply in handler(event) { deliver(reply) }
  }

  func releaseSends() {
    let held = lock.withLock {
      holdSends = false
      defer { heldSends = [] }
      return heldSends
    }
    for continuation in held { continuation.resume() }
  }

  /// Server-initiated messages, for example a revocation in the middle of a dictation.
  func deliver(_ reply: FakeServerReply) {
    switch reply {
    case .message(let object): push(.success(.binary(lock.withLock { server.seal(object) })))
    case .wrongSequence(let object, let seq):
      push(.success(.binary(lock.withLock { server.seal(object, sequence: seq) })))
    case .raw(let data): push(.success(.binary(data)))
    case .text: push(.success(.text))
    case .close(let code): push(.failure(.closed(code: code)))
    }
  }

  func receive() async throws -> RemoteTransportMessage {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if !inbox.isEmpty {
        let next = inbox.removeFirst()
        lock.unlock()
        continuation.resume(with: next.mapError { $0 as any Error })
      } else if let closedWith {
        lock.unlock()
        continuation.resume(throwing: RemoteTransportError.closed(code: closedWith))
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }

  func close(code: Int) {
    let pending = lock.withLock {
      closedWith = closedWith ?? code
      defer { waiters = [] }
      return waiters
    }
    for waiter in pending { waiter.resume(throwing: RemoteTransportError.closed(code: code)) }
  }

  private func push(_ item: Result<RemoteTransportMessage, RemoteTransportError>) {
    lock.lock()
    if !waiters.isEmpty {
      let waiter = waiters.removeFirst()
      lock.unlock()
      waiter.resume(with: item.mapError { $0 as any Error })
    } else {
      inbox.append(item)
      lock.unlock()
    }
  }
}

/// Opens fake transports; each open calls `make` so tests can script each channel.
final class FakeRemoteTransportOpener: RemoteTransportOpening, @unchecked Sendable {
  private let lock = NSLock()
  private let make: (Int) -> FakeRemoteTransport?
  private(set) var opened: [FakeRemoteTransport] = []
  private(set) var urls: [URL] = []

  init(make: @escaping (Int) -> FakeRemoteTransport?) { self.make = make }

  var openCount: Int { lock.withLock { opened.count + failures } }
  private var failures = 0

  func open(_ url: URL) async throws -> any RemoteTransport {
    let index = lock.withLock {
      urls.append(url)
      return opened.count + failures
    }
    guard let transport = make(index) else {
      lock.withLock { failures += 1 }
      throw RemoteTransportError.unreachable
    }
    lock.withLock { opened.append(transport) }
    return transport
  }
}

final class InMemoryRemoteCredentialStore: RemoteCredentialStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var items: [RemoteCredentialItem: Data] = [:]
  func read(_ item: RemoteCredentialItem) throws -> Data? { lock.withLock { items[item] } }
  func write(_ item: RemoteCredentialItem, _ value: Data) throws {
    lock.withLock { items[item] = value }
  }
  func remove(_ item: RemoteCredentialItem) throws {
    _ = lock.withLock { items.removeValue(forKey: item) }
  }
  func removeAll() throws { lock.withLock { items.removeAll() } }
  var isEmpty: Bool { lock.withLock { items.isEmpty } }
  func string(_ item: RemoteCredentialItem) -> String? {
    lock.withLock { items[item].map { String(decoding: $0, as: UTF8.self) } }
  }
}

/// Software P-256 keys standing in for the Secure Enclave.
final class SoftwareDeviceKeys: RemoteDeviceKeys, @unchecked Sendable {
  private let lock = NSLock()
  /// Handles that no longer load, as after a restore onto new hardware.
  var lostHandles: Set<Data> = []
  private(set) var created = 0

  func create() throws -> (handle: Data, publicKey: Data) {
    let key = P256.Signing.PrivateKey()
    lock.withLock { created += 1 }
    return (key.rawRepresentation, key.publicKey.x963Representation)
  }
  func publicKey(handle: Data) -> Data? {
    guard !lock.withLock({ lostHandles.contains(handle) }) else { return nil }
    return (try? P256.Signing.PrivateKey(rawRepresentation: handle))?.publicKey.x963Representation
  }
  func sign(_ message: Data, handle: Data) throws -> Data {
    guard !lock.withLock({ lostHandles.contains(handle) }) else {
      throw RemoteEnrollmentError.deviceKeyUnavailable
    }
    return try P256.Signing.PrivateKey(rawRepresentation: handle).signature(for: message)
      .derRepresentation
  }
}

final class FakeIdentitySignIn: IdentitySignIn, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var nonces: [(IdentityProvider, String)] = []
  var token = "eyJ.test.token"
  var failure: (any Error)?
  func signIn(provider: IdentityProvider, nonce: String) async throws -> String {
    lock.withLock { nonces.append((provider, nonce)) }
    if let failure { throw failure }
    return token
  }
  func isAvailable(_ provider: IdentityProvider) -> Bool { true }
}

final class FakeIdentityFetcher: RemoteIdentityFetching, @unchecked Sendable {
  var key: Data
  private(set) var fetches = 0
  init(key: Data) { self.key = key }
  func fetch(origin: URL) async throws -> RemoteServerIdentity {
    fetches += 1
    return RemoteServerIdentity(
      schemaVersion: 1, server: "flowd/test", protocolVersions: [1],
      suite: RemoteProtocol.suite, serverKey: key.base64URL,
      fingerprint: RemoteServerIdentity.fingerprint(of: key))
  }
}

/// Monotonic time that moves only when a test says so. Sleepers wake when their
/// deadline passes.
final class ManualRemoteClock: RemoteClock, @unchecked Sendable {
  private struct Sleeper {
    let id: UUID
    let deadline: Duration
    let continuation: CheckedContinuation<Void, any Error>
  }
  private let lock = NSLock()
  private var current: Duration = .seconds(1_000)
  private var sleepers: [Sleeper] = []

  func now() -> Duration { lock.withLock { current } }

  func sleep(for duration: Duration) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        lock.lock()
        if duration <= .zero || Task.isCancelled {
          lock.unlock()
          if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
          } else {
            continuation.resume()
          }
        } else {
          sleepers.append(Sleeper(id: id, deadline: current + duration, continuation: continuation))
          lock.unlock()
        }
      }
    } onCancel: {
      let cancelled = lock.withLock {
        let found = sleepers.filter { $0.id == id }
        sleepers.removeAll { $0.id == id }
        return found
      }
      for sleeper in cancelled { sleeper.continuation.resume(throwing: CancellationError()) }
    }
  }

  var sleeperCount: Int { lock.withLock { sleepers.count } }

  func advance(by duration: Duration) {
    let due = lock.withLock {
      current += duration
      let due = sleepers.filter { $0.deadline <= current }
      sleepers.removeAll { $0.deadline <= current }
      return due
    }
    for sleeper in due { sleeper.continuation.resume() }
  }
}

/// Polls until `condition` holds, yielding to other tasks; fails after about 2 s.
func eventually(
  _ condition: @escaping () async -> Bool, file: StaticString = #filePath, line: UInt = #line
) async -> Bool {
  for _ in 0..<400 {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return false
}
