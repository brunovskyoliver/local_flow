import Foundation
import LocalFlowCore
import LocalFlowSpeech

/// The meeting domain's view of speaker diarization. Nothing here imports FluidAudio.

/// Every diarization table write goes through one implementation of this.
protocol SpeakerStoring: Sendable {
  func diarization(meetingID: UUID) async throws -> MeetingDiarization?
  func admit(
    meetingID: UUID, transcriptPassID: UUID, trigger: DiarizationTrigger,
    identity: DiarizationIdentity, expectedRevision: Int64?, now: Int64
  ) async throws -> DiarizationRun
  func start(runID: UUID, now: Int64) async throws -> DiarizationRun
  /// A running run found no remote side on the system track: its microphone voices
  /// are labeled as in-room voices. The meeting's own In-room setting is unchanged.
  func markInRoom(runID: UUID) async throws
  func appendWindow(runID: UUID, speakers: [SpeakerDraft], turns: [TurnDraft], audioMs: Int64)
    async throws
  /// Folds minor clusters before adoption: each key's turns move to the target
  /// speaker (nil detaches them) and the minor speaker row goes.
  func fold(runID: UUID, speakers: [UUID: UUID?]) async throws
  func complete(runID: UUID, assignments: [AssignmentDraft], now: Int64) async throws
    -> DiarizationRun
  func fail(runID: UUID, category: DiarizationFailureCategory, detail: String?, now: Int64)
    async throws
  func interrupt(runID: UUID, now: Int64) async throws
  func requeue(runID: UUID) async throws
  /// Feature 018: where the run's windows go, and the server's model on that path.
  func recordInferencePath(
    runID: UUID, path: MeetingInferencePath, serverFailure: String?,
    model: RemoteCapabilities.Model?) async throws
  func cancel(runID: UUID) async throws
  func run(id: UUID) async throws -> DiarizationRun?
  func meetingState(meetingID: UUID) async throws -> MeetingDiarizationState
  /// The newest run that is not `superseded`, for the status line's failure.
  func latestRun(meetingID: UUID) async throws -> DiarizationRun?
  /// `pending` and `running` runs, oldest first, for launch reconciliation.
  func activeRuns(limit: Int) async throws -> [DiarizationRun]
  func turns(runID: UUID, overlapping range: Range<Int64>, after cursor: TurnCursor?, limit: Int)
    async throws -> [SpeakerTurn]
  /// Assign speakers: the accepted run's display roots with their quotes.
  func speakerSummaries(meetingID: UUID) async throws -> [SpeakerSummary]
  /// The same display roots in the same order, with their members and nothing else:
  /// no quotes, names or identities.
  func speakerRoots(meetingID: UUID) async throws -> [SpeakerRoot]
  /// Every changed name plus one `rename` correction each, in one transaction.
  func saveNames(meetingID: UUID, names: [UUID: String?], now: Int64) async throws
  /// At most 8 distinct stored names with this prefix, most recently used first.
  func nameSuggestions(prefix: String, limit: Int) async throws -> [String]
  /// FR-025: `speakerID` (and anything merged into it) displays under `targetID`.
  func merge(meetingID: UUID, speakerID: UUID, into targetID: UUID, now: Int64) async throws
  /// FR-025: clears the merge; name and color were never changed.
  func unmerge(meetingID: UUID, speakerID: UUID, now: Int64) async throws
  /// FR-026: a manual assignment for one row of the accepted run. Returns the speaker
  /// the row now shows, nil for Unknown.
  @discardableResult
  func correctSegment(
    meetingID: UUID, segmentID: UUID, to correction: SegmentCorrection, now: Int64
  )
    async throws -> UUID?
  /// FR-009: the in-room snapshot for the next run; bumps the revision.
  func setInRoom(meetingID: UUID, inRoom: Bool, now: Int64) async throws
  /// R7: corrections flagged `needs_review` by the last adoption, oldest first.
  func reviewNotices(meetingID: UUID) async throws -> [ReviewNotice]
  func dismissReview(id: UUID) async throws
}

extension SpeakerStoring {
  /// Stores without the Feature 018 columns record nothing.
  func recordInferencePath(
    runID: UUID, path: MeetingInferencePath, serverFailure: String?,
    model: RemoteCapabilities.Model?
  ) async throws {}

  func speakerRoots(meetingID: UUID) async throws -> [SpeakerRoot] {
    try await speakerSummaries(meetingID: meetingID).map {
      SpeakerRoot(id: $0.id, source: $0.source, members: $0.includes.map(\.id))
    }
  }
}

/// Transcript and meeting lifecycle events the diarization scheduler reacts to.
@MainActor protocol DiarizationObserving: AnyObject {
  /// `echoProfile` is the finalization pass's echo energy profile when it built
  /// one; the diarizer rebases and calibrates it instead of decoding the tracks
  /// again. nil means "profile yourselves" (mixed layout or an older build).
  func meetingTranscriptDidFinalize(id: UUID, echoProfile: EchoGate.Profile?)
  /// A meeting handed to the server came back with its transcript and labels merged;
  /// `labeled` is false when the server's diarization did not succeed.
  func meetingDidReturnFromServer(id: UUID, labeled: Bool)
  func meetingWillDelete(id: UUID) async
}
