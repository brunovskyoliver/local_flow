import XCTest

@testable import LocalFlow

/// T070 / FR-007a: every unfinished run becomes `interrupted` at launch; a
/// restart (through the queue, trigger `restart`) happens only for an
/// `automatic` run on a meeting with no accepted analysis while the setting
/// is on, at most once per meeting per launch.
final class IntelligenceReconcilerTests: XCTestCase {

  /// Pending and running rows — whatever the trigger — are all interrupted.
  func testUnfinishedRowsBecomeInterrupted() async throws {
    let store = FakeAnalysisStore()
    let pending = try await admit(store: store, trigger: .manual)
    let running = try await admit(store: store, trigger: .retry)
    _ = try await store.start(runID: running.id, now: 0)

    let summary = await IntelligenceReconciler(store: store, automaticEnabled: { true }).run()

    XCTAssertEqual(summary.found, 2)
    XCTAssertEqual(summary.interrupted, 2)
    let rows =
      try await store.runs(meetingID: pending.meetingID, limit: 10)
      + store.runs(meetingID: running.meetingID, limit: 10)
    XCTAssertEqual(rows.map(\.state), [.interrupted, .interrupted])
    XCTAssertTrue(rows.allSatisfy { $0.failureCategory == .interrupted && $0.completedAt != nil })
  }

  /// An automatic run on a meeting with no accepted analysis restarts while
  /// the setting is on, and the meeting is stamped `auto_restarted_at`.
  func testAutomaticWithoutAcceptedRestarts() async throws {
    let store = FakeAnalysisStore()
    let run = try await admit(store: store, trigger: .automatic)
    _ = try await store.start(runID: run.id, now: 0)

    let summary = await IntelligenceReconciler(store: store, automaticEnabled: { true }).run()

    XCTAssertEqual(summary.restarts, [run.meetingID])
    let pointer = try await store.analysis(meetingID: run.meetingID)
    XCTAssertNotNil(pointer?.autoRestartedAt)
  }

  /// Manual, retry and regenerate triggers wait for a manual Retry — they are
  /// interrupted but never restarted.
  func testNonAutomaticTriggersDoNotRestart() async throws {
    let store = FakeAnalysisStore()
    for trigger in [AnalysisTrigger.manual, .retry, .regenerate] {
      _ = try await admit(store: store, trigger: trigger)
    }
    let summary = await IntelligenceReconciler(store: store, automaticEnabled: { true }).run()
    XCTAssertEqual(summary.interrupted, 3)
    XCTAssertEqual(summary.restarts, [])
  }

  /// An automatic run whose meeting already has an accepted analysis waits
  /// for Retry rather than re-summarizing.
  func testAcceptedAnalysisBlocksRestart() async throws {
    let store = FakeAnalysisStore()
    let meetingID = UUID()
    // An earlier run was accepted; a later automatic run is the leftover.
    let accepted = try await accept(store: store, meetingID: meetingID)
    XCTAssertEqual(accepted.state, .succeeded)
    let run = try await admit(store: store, trigger: .automatic, meetingID: meetingID)
    _ = try await store.start(runID: run.id, now: 0)

    let summary = await IntelligenceReconciler(store: store, automaticEnabled: { true }).run()

    XCTAssertEqual(summary.restarts, [])
    let interrupted = try await store.runs(meetingID: meetingID, limit: 10)
    XCTAssertTrue(interrupted.contains { $0.id == run.id && $0.state == .interrupted })
  }

  /// The setting off at launch: the row is still interrupted but nothing
  /// restarts — the meeting waits for Retry.
  func testSettingOffBlocksRestart() async throws {
    let store = FakeAnalysisStore()
    let run = try await admit(store: store, trigger: .automatic)
    let summary = await IntelligenceReconciler(store: store, automaticEnabled: { false }).run()
    XCTAssertEqual(summary.interrupted, 1)
    XCTAssertEqual(summary.restarts, [])
    let pointer = try await store.analysis(meetingID: run.meetingID)
    XCTAssertNil(pointer?.autoRestartedAt)
  }

  /// Each unfinished automatic meeting restarts once — the per-meeting dedupe
  /// and the `auto_restarted_at` stamp enforce the one-per-launch bound.
  func testAtMostOneRestartPerMeeting() async throws {
    let store = FakeAnalysisStore()
    let first = try await admit(store: store, trigger: .automatic)
    let second = try await admit(store: store, trigger: .automatic)
    _ = try await store.start(runID: second.id, now: 0)

    let summary = await IntelligenceReconciler(store: store, automaticEnabled: { true }).run()

    XCTAssertEqual(Set(summary.restarts), [first.meetingID, second.meetingID])
    for meetingID in [first.meetingID, second.meetingID] {
      let pointer = try await store.analysis(meetingID: meetingID)
      XCTAssertNotNil(pointer?.autoRestartedAt)
    }
  }

  /// A meeting with no unfinished rows and no pointer restarts nothing.
  func testEmptyStoreIsQuiet() async throws {
    let store = FakeAnalysisStore()
    let summary = await IntelligenceReconciler(store: store, automaticEnabled: { true }).run()
    XCTAssertEqual(summary, IntelligenceReconciler.Summary())
  }

  // MARK: Helpers

  @discardableResult
  private func admit(
    store: FakeAnalysisStore, trigger: AnalysisTrigger, meetingID: UUID = UUID()
  ) async throws -> AnalysisRun {
    try await store.admit(
      meetingID: meetingID, trigger: trigger,
      evidence: EvidenceVersion(hex: "e"), passID: UUID(),
      policy: AnalysisPolicy(), now: 0)
  }

  /// Adopts a minimal analysis so the pointer carries `accepted_run_id`.
  private func accept(store: FakeAnalysisStore, meetingID: UUID) async throws -> AnalysisRun {
    let run = try await admit(store: store, trigger: .automatic, meetingID: meetingID)
    _ = try await store.start(runID: run.id, now: 0)
    return try await store.adopt(
      runID: run.id,
      result: ValidatedAnalysis(
        language: .en,
        summary: ValidatedSummary(text: "Summary", sources: [], wholeMeeting: true),
        topics: [], decisions: [], actionItems: [], nextSteps: [], openQuestions: [],
        risks: []),
      counts: ValidationCounts(),
      identity: RunIdentity(
        serverVersion: "0.3.0", backendKind: "test", backendModel: "test",
        promptVersions: "full=2", pipelineVersion: AnalysisPolicy.pipelineVersion),
      now: 0)
  }
}
