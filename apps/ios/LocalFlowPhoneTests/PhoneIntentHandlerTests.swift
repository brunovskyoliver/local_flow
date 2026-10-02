import XCTest

@testable import LocalFlow

/// The app's side of the intents (contracts/system-entry-points.md).
@MainActor
final class PhoneIntentHandlerTests: XCTestCase {
  private var harness: PhoneHarness!
  private var controller: SessionController!
  private var pasteboard: FakePasteboard!
  private var handler: PhoneIntentHandler!

  override func setUp() async throws {
    harness = try PhoneHarness()
    controller = harness.makeController()
    pasteboard = FakePasteboard()
    handler = PhoneIntentHandler(
      controller: controller, dictations: harness.dictations, pasteboard: pasteboard)
  }

  override func tearDown() async throws {
    handler = nil
    controller = nil
    harness = nil
  }

  private func dictate() async {
    let request = UUID()
    XCTAssertEqual(controller.start(requestID: request), .started)
    await controller.stop(requestID: request)
  }

  func testEndSessionEndsARunningSessionAndIsANoOpWithout() async {
    await handler.endSession()
    XCTAssertNil(controller.session)
    await controller.open(origin: .keyboard)
    await handler.endSession()
    XCTAssertEqual(controller.session?.state, .ended)
    XCTAssertEqual(controller.session?.endReason, .userEnded)
    XCTAssertFalse(harness.capture.engineRunning)
  }

  func testCopyLastWritesTheLastResult() async throws {
    await harness.runtime.set(text: "the newest words")
    await controller.open(origin: .keyboard)
    await dictate()
    XCTAssertEqual(controller.lastResult?.text, "the newest words")
    let copied = try await handler.copyLast()
    XCTAssertTrue(copied)
    XCTAssertEqual(pasteboard.string, "the newest words")
  }

  func testCopyLastReadsHistoryAfterARelaunch() async throws {
    await harness.runtime.set(text: "from before the relaunch")
    await controller.open(origin: .keyboard)
    await dictate()
    let relaunched = harness.makeController()
    XCTAssertNil(relaunched.lastResult)
    handler = PhoneIntentHandler(
      controller: relaunched, dictations: harness.dictations, pasteboard: pasteboard)
    _ = try await handler.copyLast()
    XCTAssertEqual(pasteboard.string, "from before the relaunch")
  }

  func testCopyLastWithNothingThrows() async {
    do {
      _ = try await handler.copyLast()
      XCTFail("copied nothing")
    } catch LocalFlowIntentError.nothingToCopy {
    } catch {
      XCTFail("\(error)")
    }
    XCTAssertTrue(pasteboard.attempts.isEmpty)
  }

  /// R4: iOS drops background writes. The newest text waits for LocalFlow to be active.
  func testADroppedWriteIsAppliedWhenTheAppBecomesActive() async throws {
    await harness.runtime.set(text: "first")
    await controller.open(origin: .keyboard)
    await dictate()
    pasteboard.accepts = false
    let copied = try await handler.copyLast()
    XCTAssertFalse(copied)
    await harness.runtime.set(text: "second")
    await dictate()
    _ = try await handler.copyLast()
    XCTAssertNil(pasteboard.string)
    pasteboard.accepts = true
    handler.becameActive()
    XCTAssertEqual(pasteboard.string, "second", "newest wins")
    handler.becameActive()
    XCTAssertEqual(pasteboard.attempts.filter { $0 == "second" }.count, 2, "applied once")
  }
}
