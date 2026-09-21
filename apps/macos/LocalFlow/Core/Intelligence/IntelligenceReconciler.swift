import Foundation
import OSLog

/// Launch reconciliation of analysis runs (FR-007a). Runs after the
/// identification reconciler on the same detached task and reads no audio.
/// Every run left `pending` or `running` is recorded `interrupted`; a meeting
/// restarts through the admission queue only when the interrupted run was
/// `automatic`, the meeting has no accepted analysis and the automatic
/// setting is on. `auto_restarted_at` stamps each restart — at most one per
/// meeting per launch, and a failed restart leaves the meeting on Generate
/// Summary.
final class IntelligenceReconciler: Sendable {
  static let maximumRows = 100

  struct Summary: Equatable, Sendable {
    var found = 0
    var interrupted = 0
    /// Meetings eligible for an FR-007a restart, oldest run first.
    var restarts: [UUID] = []
  }

  private let store: any AnalysisStoring
  private let automaticEnabled: @Sendable () async -> Bool
  private let clock: any MeetingClock
  private let logger = Logger(subsystem: "org.localflow.LocalFlow", category: "intelligence")

  init(
    store: any AnalysisStoring,
    automaticEnabled: @escaping @Sendable () async -> Bool,
    clock: any MeetingClock = SystemMeetingClock()
  ) {
    self.store = store
    self.automaticEnabled = automaticEnabled
    self.clock = clock
  }

  func run() async -> Summary {
    var summary = Summary()
    do {
      let enabled = await automaticEnabled()
      var candidates: [UUID] = []
      var seen: Set<UUID> = []
      for run in try await store.unfinishedRuns(limit: Self.maximumRows) {
        summary.found += 1
        // One damaged row does not stop the rest.
        guard
          (try? await store.interrupt(runID: run.id, now: clock.nowMilliseconds))
            != nil
        else { continue }
        summary.interrupted += 1
        guard run.trigger == .automatic, seen.insert(run.meetingID).inserted
        else { continue }
        candidates.append(run.meetingID)
      }
      for meetingID in candidates {
        // The setting can have been turned off while the app was away; an
        // accepted analysis (or a deleted meeting row) rules the restart out.
        guard enabled,
          let pointer = try? await store.analysis(meetingID: meetingID),
          pointer.acceptedRunID == nil
        else { continue }
        try? await store.markAutoRestarted(
          meetingID: meetingID, now: clock.nowMilliseconds)
        summary.restarts.append(meetingID)
      }
    } catch {
      logger.error("Intelligence reconciliation failed")
    }
    logger.notice(
      "Intelligence reconciliation: found=\(summary.found) interrupted=\(summary.interrupted) restarts=\(summary.restarts.count)"
    )
    return summary
  }
}
