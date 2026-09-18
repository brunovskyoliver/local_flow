import Foundation
import OSLog

/// Launch reconciliation of transcript rows (FR-018). Runs after
/// `MeetingReconciler.run()` on the same detached task, bounded to 100 rows per
/// launch, and reads only the meeting row for each active transcript: no file is
/// opened, no lease is taken, no audio is touched. A `live` or `pending` row is
/// marked `interrupted` (Retry offered); a `finalizing` row is left for an
/// automatic resume unless its meeting failed. Every changed row leaves one
/// `meeting_recovery_outcomes` row with the `transcript:` prefix.
final class TranscriptReconciler: Sendable {
  static let maximumRows = 100

  struct Summary: Equatable, Sendable {
    var found = 0
    var interrupted = 0
    var failed = 0
    /// `finalizing` rows whose meeting is terminal, in `updated_at` order.
    var resume: [UUID] = []
    var missingMeetings = 0
    /// Rows whose meeting is still active (deferred by the meeting reconciler).
    var deferred = 0

    var noticeText: String? {
      var parts: [String] = []
      if !resume.isEmpty {
        parts.append(
          resume.count == 1
            ? "Resuming 1 interrupted transcript"
            : "Resuming \(resume.count) interrupted transcripts")
      }
      let retryable = interrupted + failed
      if retryable > 0 {
        parts.append(
          retryable == 1
            ? "1 transcript was interrupted; choose Retry to finish it"
            : "\(retryable) transcripts were interrupted; choose Retry to finish them")
      }
      return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }
  }

  private let store: any TranscriptStoring
  private let meetings: any MeetingStoring
  private let clock: any MeetingClock
  private let recorder: ResourceRecorder?
  private let logger = Logger(subsystem: "org.localflow.LocalFlow", category: "transcript")

  init(
    store: any TranscriptStoring, meetings: any MeetingStoring,
    clock: any MeetingClock = SystemMeetingClock(), recorder: ResourceRecorder? = nil
  ) {
    self.store = store
    self.meetings = meetings
    self.clock = clock
    self.recorder = recorder
  }

  func run() async -> Summary {
    var summary = Summary()
    do {
      let rows = try await store.activeRows(limit: Self.maximumRows)
      for row in rows {
        summary.found += 1
        await reconcile(row, summary: &summary)
      }
    } catch {
      logger.error("Transcript reconciliation failed: active_rows_read")
    }
    logger.notice(
      "Transcript reconciliation: found=\(summary.found) interrupted=\(summary.interrupted) failed=\(summary.failed) resume=\(summary.resume.count) missing=\(summary.missingMeetings) deferred=\(summary.deferred)"
    )
    return summary
  }

  private func reconcile(_ row: MeetingTranscription, summary: inout Summary) async {
    guard let meeting = try? await meetings.meeting(id: row.meetingID) else {
      // Impossible with the cascade; counted so a damaged database is visible.
      summary.missingMeetings += 1
      logger.error("Transcript row without a meeting row")
      return
    }
    guard meeting.state.isTerminal else {
      summary.deferred += 1
      return
    }
    let target: TranscriptState
    switch row.state {
    case .finalizing:
      guard meeting.state == .failed else {
        summary.resume.append(row.meetingID)
        return
      }
      target = .failed
    case .live, .pending:
      target = meeting.state == .failed ? .failed : .interrupted
    case .notRequested, .final, .failed, .interrupted:
      return
    }
    let now = clock.nowMilliseconds
    do {
      try await store.recover(
        row: row, to: target,
        outcome:
          RecoveryOutcome(
            meetingID: row.meetingID, ranAt: now, foundState: meeting.state,
            foundStage: meeting.finalizationStage,
            segmentsRecovered: row.segmentCount,
            summary: "transcript:\(row.state.rawValue)->\(target.rawValue) finalization_interrupted"
          ))
      if target == .failed { summary.failed += 1 } else { summary.interrupted += 1 }
      recorder?.record(
        phase: .idle, metric: .transcriptTransition, itemCount: 1, meetingKey: target.rawValue)
    } catch {
      logger.error(
        "Transcript reconciliation write failed: recovery_write")
    }
  }
}
