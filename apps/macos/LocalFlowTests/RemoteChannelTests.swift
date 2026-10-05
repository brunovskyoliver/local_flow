import CryptoKit
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

/// Feature 014 channel crypto and framing: CryptoKit against the vectors flowd's Go
/// implementation generated, and the channel's failure rules over a fake socket.
final class RemoteChannelTests: XCTestCase {
  private struct Vectors: Decodable {
    struct Frame: Decodable {
      let seq: UInt64
      let aad: String
      let plaintext: String
      let frame: String
      var enc: String?
    }
    struct Exports: Decodable {
      let s2cInfo: String
      let binding: String
    }
    let info: String
    let serverPrivateKey: String
    let serverPublicKey: String
    let replyPrivateKey: String
    let replyPublicKey: String
    let hello: Frame
    let exports: Exports
    let serverFirst: Frame
    let c2s: [Frame]
    let s2c: [Frame]
  }

  private func vectors() throws -> Vectors {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(
      Vectors.self,
      from: Data(contentsOf: remoteFixturesURL().appendingPathComponent("hpke-vectors.json")))
  }

  func testCryptoKitOpensEveryVectorFrameAsTheServer() throws {
    let v = try vectors()
    XCTAssertEqual(Data(hex: v.info), RemoteChannelCrypto.info)
    let serverKey = try Curve25519.KeyAgreement.PrivateKey(
      rawRepresentation: Data(hex: v.serverPrivateKey))
    XCTAssertEqual(serverKey.publicKey.rawRepresentation, Data(hex: v.serverPublicKey))
    let hello = Data(hex: v.hello.frame)
    XCTAssertEqual(hello.prefix(4), RemoteChannelCrypto.magic)
    let enc = hello.subdata(in: 4..<36)
    XCTAssertEqual(enc, Data(hex: try XCTUnwrap(v.hello.enc)))
    XCTAssertEqual(hello.subdata(in: 36..<44), RemoteChannelCrypto.sequence(0))
    var recipient = try HPKE.Recipient(
      privateKey: serverKey, ciphersuite: RemoteChannelCrypto.suite,
      info: RemoteChannelCrypto.info, encapsulatedKey: enc)
    XCTAssertEqual(
      Data(hex: v.hello.aad), RemoteChannelCrypto.magic + RemoteChannelCrypto.sequence(0))
    XCTAssertEqual(
      try recipient.open(
        hello.subdata(in: 44..<hello.count), authenticating: Data(hex: v.hello.aad)),
      Data(hex: v.hello.plaintext))
    // The hello names the reply key the vectors use.
    let helloJSON = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(hex: v.hello.plaintext)) as? [String: Any])
    XCTAssertEqual(
      Data(base64URL: try XCTUnwrap(helloJSON["reply_key"] as? String)),
      Data(hex: v.replyPublicKey))
    XCTAssertEqual(
      RemoteChannelCrypto.data(
        try recipient.exportSecret(
          context: Data("localflow v1 s2c info".utf8), outputByteCount: 32)),
      Data(hex: v.exports.s2cInfo))
    XCTAssertEqual(
      RemoteChannelCrypto.data(
        try recipient.exportSecret(context: Data("localflow v1 binding".utf8), outputByteCount: 32)
      ), Data(hex: v.exports.binding))
    for frame in v.c2s {
      let bytes = Data(hex: frame.frame)
      XCTAssertEqual(bytes.prefix(8), RemoteChannelCrypto.sequence(frame.seq))
      XCTAssertEqual(Data(hex: frame.aad), RemoteChannelCrypto.sequence(frame.seq))
      XCTAssertEqual(
        try recipient.open(bytes.dropFirst(8), authenticating: bytes.prefix(8)),
        Data(hex: frame.plaintext), "c2s \(frame.seq)")
    }
    XCTAssertTrue(v.c2s.contains { Data(hex: $0.plaintext).first == 0x01 })
    XCTAssertTrue(v.c2s.contains { Data(hex: $0.plaintext).first == 0x00 })
  }

  func testChannelCryptoOpensEveryServerVectorFrame() throws {
    let v = try vectors()
    let serverKey = try Curve25519.KeyAgreement.PrivateKey(
      rawRepresentation: Data(hex: v.serverPrivateKey))
    var crypto = try RemoteChannelCrypto(
      serverKey: serverKey.publicKey,
      replyKey: .init(rawRepresentation: Data(hex: v.replyPrivateKey)),
      s2cInfo: Data(hex: v.exports.s2cInfo))
    let first = Data(hex: v.serverFirst.frame)
    XCTAssertEqual(first.prefix(32), Data(hex: try XCTUnwrap(v.serverFirst.enc)))
    XCTAssertEqual(try crypto.open(first), Data(hex: v.serverFirst.plaintext).dropFirst())
    for frame in v.s2c {
      XCTAssertEqual(
        try crypto.open(Data(hex: frame.frame)), Data(hex: frame.plaintext).dropFirst(),
        "s2c \(frame.seq)")
    }
  }

  func testRepeatedOrSkippedServerFramesAreRefused() throws {
    let v = try vectors()
    let serverKey = try Curve25519.KeyAgreement.PrivateKey(
      rawRepresentation: Data(hex: v.serverPrivateKey))
    func fresh() throws -> RemoteChannelCrypto {
      try RemoteChannelCrypto(
        serverKey: serverKey.publicKey,
        replyKey: .init(rawRepresentation: Data(hex: v.replyPrivateKey)),
        s2cInfo: Data(hex: v.exports.s2cInfo))
    }
    var replay = try fresh()
    _ = try replay.open(Data(hex: v.serverFirst.frame))
    _ = try replay.open(Data(hex: v.s2c[0].frame))
    XCTAssertThrowsError(try replay.open(Data(hex: v.s2c[0].frame)))
    var skip = try fresh()
    _ = try skip.open(Data(hex: v.serverFirst.frame))
    XCTAssertThrowsError(try skip.open(Data(hex: v.s2c[1].frame)))
    var corrupt = try fresh()
    var bytes = Data(hex: v.serverFirst.frame)
    bytes[bytes.count - 1] ^= 0x01
    XCTAssertThrowsError(try corrupt.open(bytes))
  }

  func testAChannelTalksToTheFakeServer() async throws {
    let transport = FakeRemoteTransport { event in
      switch event {
      case .hello: return [.message(["type": "ready"])]
      case .control(let object) where object["type"] as? String == "dictation_start":
        return [.message(["type": "progress", "op": 1, "state": "queued"])]
      default: return []
      }
    }
    let channel = try RemoteChannel(transport: transport, serverKey: transport.server.publicKey)
    try await channel.open(purpose: .session, accessToken: "lfa_token")
    let binding = await channel.binding
    XCTAssertEqual(binding, transport.server.binding)
    try await channel.send(.dictationStart(op: 1, boost: nil))
    try await channel.sendAudio([0.25, -0.5][...])
    guard case .progress(1, "queued") = try await channel.receive() else {
      return XCTFail("expected progress")
    }
    let delivered = await eventually { transport.audioSamples == [0.25, -0.5] }
    XCTAssertTrue(delivered)
    guard case .hello(let purpose, let token, _) = transport.receivedEvents.first else {
      return XCTFail("expected hello")
    }
    XCTAssertEqual(purpose, "session")
    XCTAssertEqual(token, "lfa_token")
  }

  func testCloseCode4001IsAPinMismatch() async throws {
    // A channel sealed to another key: the server cannot open the hello.
    let transport = FakeRemoteTransport()
    let other = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    let channel = try RemoteChannel(transport: transport, serverKey: other)
    do {
      try await channel.open(purpose: .session, accessToken: "lfa_x")
      XCTFail("expected pin mismatch")
    } catch {
      XCTAssertEqual(error as? RemoteChannelError, .pinMismatch)
      XCTAssertEqual((error as? RemoteChannelError)?.failureReason, .pinMismatch)
    }
  }

  func testOutOfSequenceOrUnopenableServerFramesCloseTheChannel() async throws {
    for bad in [
      FakeServerReply.wrongSequence(["type": "progress", "op": 1, "state": "queued"], 5),
      .raw(Data(repeating: 7, count: 60)),
      .text,
    ] {
      let transport = FakeRemoteTransport { event in
        if case .hello = event { return [.message(["type": "ready"])] }
        return []
      }
      let channel = try RemoteChannel(transport: transport, serverKey: transport.server.publicKey)
      try await channel.open(purpose: .session, accessToken: "lfa_x")
      transport.deliver(bad)
      do {
        _ = try await channel.receive()
        XCTFail("expected a protocol error")
      } catch {
        XCTAssertEqual(error as? RemoteChannelError, .protocolError)
      }
      XCTAssertNotNil(transport.closedWith)
      // Nothing more is sent on a failed channel.
      do {
        try await channel.send(.dictationCancel(op: 1))
        XCTFail("expected the channel to stay failed")
      } catch {
        XCTAssertEqual(error as? RemoteChannelError, .protocolError)
      }
    }
  }

  func testServerErrorAtHelloIsReported() async throws {
    let transport = FakeRemoteTransport { event in
      if case .hello = event { return [.message(["type": "error", "code": "token_expired"])] }
      return []
    }
    let channel = try RemoteChannel(transport: transport, serverKey: transport.server.publicKey)
    do {
      try await channel.open(purpose: .session, accessToken: "lfa_old")
      XCTFail("expected an error")
    } catch {
      XCTAssertEqual(error as? RemoteChannelError, .server(.tokenExpired))
    }
  }

  func testSendersWaitForTheSocketInsteadOfFailing() async throws {
    let transport = FakeRemoteTransport { event in
      if case .hello = event { return [.message(["type": "ready"])] }
      return []
    }
    let channel = try RemoteChannel(transport: transport, serverKey: transport.server.publicKey)
    try await channel.open(purpose: .session, accessToken: "lfa_x")
    transport.holdSends = true
    // A whole recording flushed at once, as a retry or a reconnect does.
    let sender = Task {
      for index in 0..<12 {
        try await channel.sendAudio(Array(repeating: Float(index), count: 1_600)[...])
      }
    }
    try? await Task.sleep(for: .milliseconds(50))
    transport.releaseSends()
    try await sender.value
    let delivered = await eventually { transport.audioSamples.count == 12 * 1_600 }
    XCTAssertTrue(delivered)
    XCTAssertEqual(transport.audioSamples.last, 11)
  }

  func testASocketThatTakesNothingFailsWithTimeout() async throws {
    let transport = FakeRemoteTransport { event in
      if case .hello = event { return [.message(["type": "ready"])] }
      return []
    }
    let channel = try RemoteChannel(
      transport: transport, serverKey: transport.server.publicKey,
      stallTimeout: .milliseconds(50))
    try await channel.open(purpose: .session, accessToken: "lfa_x")
    transport.holdSends = true
    var failure: RemoteChannelError?
    for _ in 0..<8 {
      do { try await channel.sendAudio(Array(repeating: 0.1, count: 1_600)[...]) } catch {
        failure = error as? RemoteChannelError
        break
      }
    }
    XCTAssertEqual(failure, .timeout)
    XCTAssertNotNil(transport.closedWith)
    transport.releaseSends()
  }

  func testAudioFramesAreBounded() async throws {
    let transport = FakeRemoteTransport { event in
      if case .hello = event { return [.message(["type": "ready"])] }
      return []
    }
    let channel = try RemoteChannel(transport: transport, serverKey: transport.server.publicKey)
    try await channel.open(purpose: .session, accessToken: "lfa_x")
    do {
      try await channel.sendAudio(Array(repeating: 0, count: 16_001)[...])
      XCTFail("expected refusal")
    } catch {}
  }
}
