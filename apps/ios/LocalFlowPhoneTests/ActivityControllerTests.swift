import XCTest

@testable import LocalFlow

/// The session's Live Activity (US5, research R3): one per session, one update per phase,
/// ended with the session, never a condition for the session itself.
@MainActor
final class ActivityControllerTests: XCTestCase {
  private var harness: PhoneHarness!
  private var controller: SessionController!
  private var requester: FakeActivityRequester!
  private var activity: ActivityController!

  override func setUp() async throws {
    harness = try PhoneHarness()
    controller = harness.makeController()
    requester = FakeActivityRequester()
    activity = ActivityController(
      controller: controller, requester: requester,
      idleTimeout: { [unowned self] in harness.timeout })
    activity.start()
  }

  override func tearDown() async throws {
    activity = nil
    controller = nil
    harness = nil
  }

  private func dictate() async {
    let request = UUID()
    XCTAssertEqual(controller.start(requestID: request), .started)
    await controller.stop(requestID: request)
  }

  func testSessionStartRequestsOneSessionActivity() async throws {
    await controller.open(origin: .keyboard)
    let session = try XCTUnwrap(controller.session)
    XCTAssertEqual(
      requester.calls,
      [.request(.session, .init(phase: .idle, deadline: session.idleDeadline, noTimeout: false))])
    XCTAssertNotNil(session.idleDeadline)
  }

  func testAnExistingActivityIsEndedBeforeTheRequest() async {
    requester.live = 1  // left over from an earlier process
    activity = ActivityController(
      controller: controller, requester: requester,
      idleTimeout: { [unowned self] in harness.timeout })
    activity.start()
    XCTAssertEqual(requester.calls, [.end(nil, .immediate)])
    requester.live = 1  // a leftover the launch did not see
    await controller.open(origin: .keyboard)
    XCTAssertEqual(requester.calls.count, 3)
    XCTAssertEqual(requester.calls[1], .end(nil, .immediate))
    XCTAssertEqual(requester.requests.count, 1)
    XCTAssertEqual(requester.live, 1)
  }

  func testEachPhaseChangeIsExactlyOneUpdate() async throws {
    await controller.open(origin: .keyboard)
    let request = UUID()
    controller.start(requestID: request)
    // A route change mid-recording changes nothing the activity shows.
    harness.capture.inputName = "AirPods"
    harness.capture.onRouteChange?()
    controller.tick()
    harness.now += 10
    await controller.stop(requestID: request)
    XCTAssertEqual(requester.updates.map(\.phase), [.recording, .transcribing, .idle])
    let recording = requester.updates[0]
    XCTAssertNil(recording.deadline)
    XCTAssertEqual(recording.recordingStartedAt, harness.now.addingTimeInterval(-10))
    let idle = try XCTUnwrap(requester.updates.last)
    XCTAssertEqual(idle.deadline, controller.session?.idleDeadline)
    XCTAssertNil(idle.recordingStartedAt)
    XCTAssertTrue(idle.canCopy)
    XCTAssertNil(idle.preview, "a session activity shows no transcript text")
    XCTAssertEqual(requester.requests.count, 1)
  }

  func testNeverHasNoDeadlineAndSaysNoTimeout() async {
    harness.timeout = .never
    await controller.open(origin: .keyboard)
    guard case .request(_, let state) = requester.calls.first else { return XCTFail() }
    XCTAssertNil(state.deadline)
    XCTAssertTrue(state.noTimeout)
    await dictate()
    XCTAssertTrue(requester.updates.allSatisfy(\.noTimeout))
    XCTAssertTrue(requester.updates.allSatisfy { $0.deadline == nil })
  }

  func testTheActivityEndsImmediatelyWithTheSession() async {
    await controller.open(origin: .keyboard)
    controller.end(.userEnded)
    XCTAssertEqual(requester.calls.last, .end(nil, .immediate))
    XCTAssertFalse(requester.isActive)
    // A second end does not end it again.
    controller.end(.userEnded)
    XCTAssertEqual(requester.calls.filter { $0 == .end(nil, .immediate) }.count, 1)
  }

  func testSessionStartsWithoutLiveActivities() async {
    requester.areActivitiesEnabled = false
    await controller.open(origin: .keyboard)
    XCTAssertEqual(controller.session?.state, .ready)
    XCTAssertTrue(requester.calls.isEmpty)
    requester.areActivitiesEnabled = true
    requester.requestFails = true
    controller.end(.userEnded)
    await controller.open(origin: .keyboard)
    XCTAssertEqual(controller.session?.state, .ready)
    XCTAssertTrue(requester.requests.isEmpty)
  }

  /// The 8-hour limit or a swipe ends the activity; it returns when LocalFlow comes forward.
  func testTheActivityReturnsWhenTheAppBecomesActive() async {
    harness.timeout = .never
    await controller.open(origin: .keyboard)
    requester.systemEnded()
    activity.becameActive()
    XCTAssertEqual(requester.requests.count, 2)
    activity.becameActive()
    XCTAssertEqual(requester.requests.count, 2)
  }
}
