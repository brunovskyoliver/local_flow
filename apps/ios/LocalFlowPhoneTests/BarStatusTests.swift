import XCTest

@testable import LocalFlow

final class BarStatusTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_790_000_000)

  private func session(
    _ state: SessionFile.State = .ready, timeout: String = "5m", deadline: Date? = nil,
    source: SessionFile.Source? = nil
  ) -> SessionFile {
    SessionFile(
      sessionID: UUID(), state: state, idleDeadline: deadline.map(Handoff.milliseconds),
      idleTimeout: timeout, updatedAt: 0, dictationSource: source)
  }

  func testCountsDownToTheIdleDeadline() {
    let file = session(deadline: now.addingTimeInterval(252))
    XCTAssertEqual(BarStatus.text(session: file, hasPending: false, now: now), "Listening · 4:12")
    XCTAssertEqual(
      BarStatus.text(session: file, hasPending: false, now: now.addingTimeInterval(251.5)),
      "Listening · 0:01")
    XCTAssertEqual(
      BarStatus.text(session: file, hasPending: false, now: now.addingTimeInterval(400)),
      "Listening · 0:00", "never negative")
  }

  func testNeverAndAfterOne() {
    XCTAssertEqual(
      BarStatus.text(session: session(timeout: "never"), hasPending: false, now: now),
      "Listening · no timeout")
    XCTAssertEqual(
      BarStatus.text(
        session: session(timeout: "afterOne", deadline: now.addingTimeInterval(60)),
        hasPending: false, now: now),
      "Listening · after this dictation")
  }

  func testNothingWithoutASession() {
    XCTAssertNil(BarStatus.text(session: nil, hasPending: false, now: now))
    XCTAssertNil(BarStatus.text(session: session(.ended), hasPending: false, now: now))
  }

  func testControlRecordingIsElsewhereUnlessThisKeyboardAsked() {
    let file = session(.recording, source: .control)
    XCTAssertEqual(
      BarStatus.text(session: file, hasPending: false, now: now), BarStatus.elsewhere)
    XCTAssertNotEqual(
      BarStatus.text(session: file, hasPending: true, now: now), BarStatus.elsewhere)
  }

  func testListeningElapsedAndLimitWarning() {
    XCTAssertEqual(BarStatus.listening(startedAt: nil, now: now), "Listening")
    XCTAssertEqual(
      BarStatus.listening(startedAt: now.addingTimeInterval(-3), now: now), "Listening · 0:03")
    XCTAssertEqual(
      BarStatus.listening(startedAt: now.addingTimeInterval(-269), now: now), "Listening · 4:29")
    XCTAssertEqual(
      BarStatus.listening(startedAt: now.addingTimeInterval(-276), now: now),
      "Stops at 5:00 · 0:24 left")
    XCTAssertEqual(
      BarStatus.listening(startedAt: now.addingTimeInterval(-400), now: now),
      "Stops at 5:00 · 0:00 left")
  }
}
