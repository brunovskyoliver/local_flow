import XCTest

@testable import LocalFlow

final class TranscriptLifecycleTests: XCTestCase {
  func testEntireTransitionMatrix() throws {
    let allowed: [TranscriptState: Set<TranscriptState>] = [
      .notRequested: [.pending], .pending: [.live, .finalizing, .failed, .interrupted],
      .live: [.finalizing, .failed, .interrupted], .finalizing: [.final, .failed, .interrupted],
      .final: [.finalizing], .failed: [.finalizing], .interrupted: [.finalizing],
    ]
    for from in TranscriptState.allCases {
      XCTAssertEqual(from.isActive, [.pending, .live, .finalizing].contains(from))
      XCTAssertEqual(from.isStable, !from.isActive)
      for to in TranscriptState.allCases {
        if allowed[from, default: []].contains(to) {
          XCTAssertNoThrow(try TranscriptLifecycle.transition(from: from, to: to))
        } else {
          XCTAssertThrowsError(try TranscriptLifecycle.transition(from: from, to: to)) {
            XCTAssertEqual($0 as? TranscriptStore.Error, .invalidTransition(from: from, to: to))
          }
        }
      }
    }
  }
  func testClosedFailureAndLiveStateSets() {
    XCTAssertEqual(
      Set(TranscriptFailureCategory.allCases.map(\.rawValue)),
      Set([
        "model_unavailable", "model_provisioning", "model_load_failure", "audio_decode_failure",
        "analysis_stream_failure", "runtime_failure", "finalization_interrupted",
        "persistence_failure", "persistence_capacity",
      ]))
    XCTAssertEqual(
      Set(LiveState.allCases.map(\.rawValue)),
      Set(["live", "catching_up", "degraded", "suspended", "stopped"]))
    for category in TranscriptFailureCategory.allCases {
      let text = TranscriptErrorMessage.message(for: category)
      XCTAssertFalse(text.isEmpty)
      XCTAssertFalse(text.contains("/"))
      XCTAssertFalse(text.contains("%@"))
    }
  }
}
