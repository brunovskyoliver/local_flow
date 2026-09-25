import XCTest

@testable import LocalFlow

final class MeetingLifecycleTests: XCTestCase {
  private let allowed: [(MeetingState, MeetingState)] = [
    (.created, .preparing), (.created, .failed),
    (.preparing, .recording), (.preparing, .failed), (.preparing, .interrupted),
    (.recording, .paused), (.recording, .finalizing), (.recording, .interrupted),
    (.recording, .failed),
    (.paused, .recording), (.paused, .finalizing), (.paused, .interrupted), (.paused, .failed),
    (.finalizing, .completed), (.finalizing, .interrupted), (.finalizing, .failed),
  ]

  func testEveryAllowedPairIsAccepted() throws {
    for (from, to) in allowed {
      XCTAssertEqual(try MeetingLifecycle.transition(from: from, to: to), to, "\(from) → \(to)")
    }
  }

  /// The full 8×8 sweep: every pair outside the table throws and names both states.
  func testEveryOtherPairIsRejectedWithoutSideEffects() {
    var rejected = 0
    for from in MeetingState.allCases {
      for to in MeetingState.allCases {
        guard !allowed.contains(where: { $0 == from && $1 == to }) else { continue }
        XCTAssertThrowsError(try MeetingLifecycle.transition(from: from, to: to), "\(from) → \(to)")
        {
          XCTAssertEqual(
            $0 as? MeetingLifecycle.Error, .invalidTransition(from: from, to: to))
        }
        rejected += 1
      }
    }
    XCTAssertEqual(rejected, 64 - allowed.count)
  }

  func testTerminalAndActiveStates() {
    for state in [MeetingState.completed, .interrupted, .failed] {
      XCTAssertTrue(state.isTerminal, "\(state)")
      XCTAssertFalse(state.isActive, "\(state)")
      for to in MeetingState.allCases {
        XCTAssertFalse(MeetingLifecycle.isAllowed(from: state, to: to), "\(state) → \(to)")
      }
    }
    XCTAssertEqual(
      MeetingState.allCases.filter(\.isActive),
      [.created, .preparing, .recording, .paused, .finalizing])
  }

  func testReasonSetHasTwelveCasesWithPlaceholderFreeText() {
    XCTAssertEqual(MeetingFailureReason.allCases.count, 12)
    XCTAssertEqual(
      Set(MeetingFailureReason.allCases.map(\.rawValue)),
      [
        "not_running_at_last_state", "storage_write_failed", "storage_unavailable",
        "encoder_failed", "permission_revoked", "device_lost", "stream_stopped",
        "both_sources_failed", "record_missing", "file_missing", "segment_open_failed",
        "unrecoverable_media",
      ])
    for reason in MeetingFailureReason.allCases {
      for track in [MeetingTrackKind?.none, .microphone, .system] {
        let text = MeetingErrorMessage.text(for: reason, track: track)
        XCTAssertFalse(text.isEmpty, "\(reason)")
        XCTAssertFalse(text.contains("%@"), text)
        XCTAssertFalse(text.contains("<"), text)
        XCTAssertFalse(text.contains("/"), text)
        XCTAssertFalse(text.lowercased().contains("title"), text)
      }
    }
    XCTAssertEqual(
      MeetingErrorMessage.text(for: .permissionRevoked, track: .microphone),
      "Microphone permission was revoked during the meeting.")
    XCTAssertEqual(
      MeetingErrorMessage.text(for: .permissionRevoked, track: .system),
      "System audio permission was revoked during the meeting.")
    XCTAssertEqual(
      MeetingErrorMessage.text(for: .deviceLost),
      "The microphone disconnected. The meeting continued with system audio.")
    XCTAssertEqual(
      MeetingErrorMessage.text(for: .bothSourcesFailed),
      "Recording stopped because both audio sources failed.")
  }

  func testFallbackTitleIsDerivedFromCreatedAt() {
    let createdAt: Int64 = 1_700_000_000_000
    let title = fallbackTitle(createdAt: createdAt, timeZone: TimeZone(identifier: "UTC")!)
    // English whatever the system locale; the title is sent to the server.
    XCTAssertEqual(title, "Meeting 14 Nov 2023, 22:13")
    XCTAssertEqual(meetingDurationText(61_000), "1:01")
    XCTAssertEqual(meetingDurationText(3_661_000), "1:01:01")
  }
}
