import XCTest

@testable import LocalFlow

/// Feature 018 T013 (research R11).
final class RemoteCapabilitiesTests: XCTestCase {
  func testAReadyWithoutCapabilitiesIsAFeature014Server() throws {
    guard
      case .ready(let capabilities) = try RemoteServerMessage.decode(
        Data(#"{"schema_version":1,"type":"ready"}"#.utf8))
    else { return XCTFail("not ready") }
    XCTAssertEqual(capabilities, .feature014)
    XCTAssertEqual(capabilities.ops, ["dictation_start", "rewrite"])
    XCTAssertFalse(capabilities.offers(op: "analysis"))
    XCTAssertNil(capabilities.voiceModel)
  }

  func testCapabilitiesAndTheVoiceModelDecode() throws {
    let hash = String(repeating: "a", count: 64)
    let json = """
      {"schema_version":1,"type":"ready","capabilities":{
        "ops":["dictation_start","rewrite","analysis","meeting_job"],
        "meeting_jobs":["transcribe","embed"],
        "models":{"voice":{"engine":"FluidAudio","model_id":"wespeaker","model_revision":"r1",
          "manifest_hash":"\(hash)","dimension":256}}}}
      """
    guard case .ready(let capabilities) = try RemoteServerMessage.decode(Data(json.utf8)) else {
      return XCTFail("not ready")
    }
    XCTAssertTrue(capabilities.offers(op: "analysis"))
    XCTAssertTrue(capabilities.offers(meetingJob: "transcribe"))
    XCTAssertFalse(capabilities.offers(meetingJob: "diarize"))
    XCTAssertEqual(
      capabilities.voiceModel,
      VoiceModelIdentity(
        engine: "FluidAudio", modelID: "wespeaker", modelRevision: "r1", manifestHash: hash,
        dimension: 256))
  }

  func testNotOfferedRemovesTheCapabilityUntilTheNextReady() throws {
    var capabilities = RemoteCapabilities(
      ops: ["dictation_start", "rewrite", "analysis", "meeting_job"],
      meetingJobs: ["transcribe", "diarize"], models: nil)
    capabilities.notOffered(op: "analysis")
    XCTAssertFalse(capabilities.offers(op: "analysis"))
    capabilities.notOffered(op: "meeting_job", kind: "diarize")
    XCTAssertFalse(capabilities.offers(meetingJob: "diarize"))
    XCTAssertTrue(capabilities.offers(meetingJob: "transcribe"))
    XCTAssertEqual(
      try RemoteServerMessage.decode(
        Data(#"{"schema_version":1,"type":"error","code":"not_offered","op":3}"#.utf8)
      ).op, 3)
  }

  func testTheChannelKeepsWhatReadyOffered() async throws {
    let transport = FakeRemoteTransport { event in
      guard case .hello = event else { return [] }
      return [.message(["type": "ready", "capabilities": ["ops": ["rewrite", "analysis"]]])]
    }
    let channel = try RemoteChannel(transport: transport, serverKey: transport.server.publicKey)
    try await channel.open(purpose: .session, accessToken: "lfa_1")
    let offered = await channel.capabilities
    XCTAssertEqual(offered.ops, ["rewrite", "analysis"])
    XCTAssertEqual(offered.meetingJobs, [])
  }
}
