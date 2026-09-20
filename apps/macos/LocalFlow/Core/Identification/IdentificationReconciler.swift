import Foundation
import OSLog

/// Launch reconciliation of identification runs (research R7). Runs after
/// `DiarizationReconciler` on the same detached task, at most 100 runs per launch, and
/// reads no audio. A `running` run is `interrupted` (its candidates go, the accepted
/// assignments stay); a `pending` run is handed back for the queue.
final class IdentificationReconciler: Sendable {
  static let maximumRows = 100

  struct Summary: Equatable, Sendable {
    var found = 0
    var interrupted = 0
    /// Meetings with a `pending` run, oldest first.
    var resume: [UUID] = []
  }

  private let store: any IdentityStoring
  private let clock: any MeetingClock
  private let logger = Logger(subsystem: "org.localflow.LocalFlow", category: "identification")

  init(store: any IdentityStoring, clock: any MeetingClock = SystemMeetingClock()) {
    self.store = store
    self.clock = clock
  }

  func run() async -> Summary {
    var summary = Summary()
    do {
      for run in try await store.activeRuns(limit: Self.maximumRows) {
        summary.found += 1
        switch run.state {
        case .running:
          // One damaged row does not stop the rest.
          guard (try? await store.interrupt(runID: run.id, now: clock.nowMilliseconds)) != nil
          else { continue }
          summary.interrupted += 1
        case .pending:
          summary.resume.append(run.meetingID)
        default: break
        }
      }
    } catch {
      logger.error("Identification reconciliation failed")
    }
    logger.notice(
      "Identification reconciliation: found=\(summary.found) interrupted=\(summary.interrupted) resume=\(summary.resume.count)"
    )
    return summary
  }
}
