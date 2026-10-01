import XCTest

@testable import LocalFlow
@testable import LocalFlowSpeech

/// Feature 018 T074: which coordinator a meeting stage gets.
final class MeetingInferenceRouterTests: XCTestCase {
  private let local = ModelLifecycleCoordinator { FakeTranscriptionRuntime() }
  private let remote = ModelLifecycleCoordinator { FakeTranscriptionRuntime() }
  private let live = ModelLifecycleCoordinator { FakeTranscriptionRuntime() }

  func testTheServerPathWhenServedConsentedAndNotRunLocally() async {
    let inputs = RouterInputs()
    let router = inputs.router(local: local, background: remote, live: live)
    let meeting = UUID()
    for service in [ServerService.finalTranscript, .diarization, .voiceRegions] {
      let choice = await router.choose(service, meeting: meeting)
      XCTAssertTrue(choice.lifecycle === remote, "\(service)")
      XCTAssertEqual(choice.path, .server)
      XCTAssertNotNil(choice.model)
    }
    let preview = await router.choose(.livePreview, meeting: meeting)
    XCTAssertTrue(preview.lifecycle === live)
    let voice = await router.choose(.voiceRegions, meeting: meeting)
    XCTAssertEqual(voice.model?.dimension, 256, "the identity comes from ready.capabilities")
  }

  func testEveryOtherCaseStaysOnThisMac() async {
    let inputs = RouterInputs()
    let router = inputs.router(local: local, background: remote, live: live)
    let meeting = UUID()
    var routing = ServerRouting.servingMeetings()
    routing.consentCurrent = false
    let cases: [ServerRouting?] = [
      nil, .servingMeetings(on: false), routing,
      {
        var r = ServerRouting.servingMeetings()
        r.meetings = .thisMac
        return r
      }(),
      {
        var r = ServerRouting.servingMeetings()
        r.capabilities.notOffered(op: "meeting_job", kind: "diarize")
        return r
      }(),
    ]
    for (index, routing) in cases.enumerated() {
      inputs.routing = routing
      let choice = await router.choose(.diarization, meeting: meeting)
      XCTAssertTrue(choice.lifecycle === local, "case \(index)")
      XCTAssertEqual(choice.path, .local, "case \(index)")
      XCTAssertNil(choice.model)
    }
    // Run on this Mac: local, recorded as after a server failure.
    inputs.routing = .servingMeetings()
    inputs.runLocally(meeting)
    let choice = await router.choose(.finalTranscript, meeting: meeting)
    XCTAssertTrue(choice.lifecycle === local)
    XCTAssertEqual(choice.path, .localAfterServerFailure)
    XCTAssertEqual(choice.serverFailure, "user_ran_locally")
    let other = await router.choose(.finalTranscript, meeting: UUID())
    XCTAssertEqual(other.path, .server, "the choice is per meeting")
  }

  /// The choice is made when a stage takes its lease: a switch change applies to the
  /// next lease only.
  func testTheChoiceIsMadeAtLeaseAcquisition() async {
    let inputs = RouterInputs()
    let router = inputs.router(local: local, background: remote)
    let first = await router.choose(.finalTranscript, meeting: UUID())
    inputs.routing = .servingMeetings(on: false)
    XCTAssertTrue(first.lifecycle === remote, "a choice already made stands")
    let next = await router.choose(.finalTranscript, meeting: UUID())
    XCTAssertTrue(next.lifecycle === local)
  }

  /// The remote coordinators hold runtimes that only send requests (FR-013).
  func testRemoteCoordinatorsNeverLoadALocalModel() async throws {
    let pool = RemoteChannelPool(open: { throw RemoteChannelError.unreachable })
    let coordinators = MeetingInferenceRouter.remoteCoordinators(
      pool: pool, terms: { ["LocalFlow"] }, notOffered: { _ in })
    let lease = try await coordinators.background.acquire(
      session: UUID(), workload: .meetingTranscription, meetingLanguage: .slovak)
    do {
      _ = try await coordinators.background.transcribe(
        lease, samples: [Float](repeating: 0, count: 16_000))
      XCTFail("an unreachable server answers nothing")
    } catch let waiting as RemoteMeetingWaiting {
      XCTAssertEqual(waiting.code, "unreachable")
    }
    try await coordinators.background.finish(lease)
    let diarize = try await coordinators.background.acquire(session: UUID(), workload: .diarization)
    try await coordinators.background.finish(diarize)
  }
}
