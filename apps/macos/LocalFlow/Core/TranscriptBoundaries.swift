import Foundation

@MainActor protocol MeetingTranscriptionObserving: AnyObject, Sendable {
  func meetingWillStart(id: UUID, options: MeetingStartOptions) async -> TranscriptState
  func stretchDidStart(
    meetingID: UUID, sequence: Int, tracks: [MeetingTrackKind: MeetingSourceFormat]
  ) -> [MeetingTrackKind: MeetingAnalysisTap]?
  func meetingDidPause(id: UUID)
  func meetingDidStop(id: UUID)
  func meetingDidComplete(id: UUID, detail: MeetingDetail)
  func meetingWillDelete(id: UUID) async
}
protocol TranscriptStoring: Sendable {
  func transcription(meetingID: UUID) async throws -> MeetingTranscription?
  @discardableResult func transition(
    meetingID: UUID, to: TranscriptState, now: Int64, effects: [TranscriptTransitionEffect]
  ) async throws -> MeetingTranscription
  func setLiveState(meetingID: UUID, liveState: LiveState?, now: Int64) async throws
  func updateLiveMetadata(
    meetingID: UUID, descriptor: AnalysisStreamDescriptor,
    incrementModelReloads: Bool, now: Int64
  ) async throws -> MeetingTranscription
  func appendSegments(
    meetingID: UUID, passID: UUID, drafts: [TranscriptSegmentDraft],
    progress: FinalizationProgress?, now: Int64
  ) async throws -> Int
  func appendGap(_ gap: LiveGap) async throws
  func completeFinalPass(
    meetingID: UUID, passID: UUID, descriptor: AnalysisStreamDescriptor, coveredMs: Int64,
    now: Int64
  ) async throws -> MeetingTranscription
  func discardPass(meetingID: UUID, passID: UUID) async throws
  /// A `finalizing` row starts a new final pass without a lifecycle self-transition:
  /// rows of an earlier final pass are removed, progress is cleared, the effects apply.
  func restartFinalPass(
    meetingID: UUID, passID: UUID, now: Int64, effects: [TranscriptTransitionEffect]
  ) async throws -> MeetingTranscription
  /// Rows persisted so far by one pass; the next ordinal a resumed pass must use.
  func passSegmentCount(meetingID: UUID, passID: UUID) async throws -> Int
  func page(meetingID: UUID, finality: SegmentFinality, after ordinal: Int?, limit: Int)
    async throws -> [TranscriptSegment]
  /// `page` plus each row's speaker label from the accepted diarization run (Feature 007).
  func labeledPage(meetingID: UUID, finality: SegmentFinality, after ordinal: Int?, limit: Int)
    async throws -> [LabeledSegment]
  /// The accepted run's speakers, or nil when there is no current result.
  func acceptedSpeakers(meetingID: UUID) async throws -> AcceptedSpeakers?
  /// The final-pass ordinal of one segment; nil when no such row exists.
  func ordinal(meetingID: UUID, segmentID: UUID) async throws -> Int?
  func gaps(meetingID: UUID) async throws -> [LiveGap]
  func activeRows(limit: Int) async throws -> [MeetingTranscription]
  /// Commits the recovery transition and its outcome together.
  func recover(row: MeetingTranscription, to: TranscriptState, outcome: RecoveryOutcome)
    async throws
  func recordOutcome(_ outcome: RecoveryOutcome) async throws
  func usage() async throws -> TranscriptUsage
}
enum TranscriptTransitionEffect: Sendable {
  case setIdentity(
    engine: String, model: TranscriptModelIdentity, pipeline: String, planner: String,
    vocabulary: VocabularySnapshot)
  case setDescriptor(AnalysisStreamDescriptor)
  case setPass(id: UUID, kind: TranscriptPassKind)
  case setFailure(category: TranscriptFailureCategory, detail: String?)
  case clearFailure
  case setProgress(FinalizationProgress)
  case incrementModelReloads
  /// expectedRevision makes admission atomic without adding a ninth effect.
  case setTimestamps(
    startedAt: Int64? = nil, liveStartedAt: Int64? = nil, finalizationStartedAt: Int64? = nil,
    finalizedAt: Int64? = nil, recordedMsAtPass: Int64? = nil, expectedRevision: Int64? = nil)
}

// Stores without diarization tables serve Feature 006 rows: no labels, no speakers.
extension TranscriptStoring {
  func labeledPage(meetingID: UUID, finality: SegmentFinality, after ordinal: Int?, limit: Int)
    async throws -> [LabeledSegment]
  {
    try await page(meetingID: meetingID, finality: finality, after: ordinal, limit: limit).map {
      LabeledSegment(segment: $0, label: nil)
    }
  }
  func acceptedSpeakers(meetingID: UUID) async throws -> AcceptedSpeakers? { nil }
  /// Stores without an id index walk final pages; `TranscriptStore` answers directly.
  func ordinal(meetingID: UUID, segmentID: UUID) async throws -> Int? {
    var after: Int? = nil
    while true {
      let rows = try await page(
        meetingID: meetingID, finality: .final, after: after, limit: 200)
      if let hit = rows.first(where: { $0.id == segmentID }) { return hit.ordinal }
      guard rows.count == 200 else { return nil }
      after = rows.last?.ordinal
    }
  }
}

// Test doubles may use the ordinary operations; the SQLite store overrides this
// requirement with one transaction so a failed outcome insert rolls back recovery.
extension TranscriptStoring {
  func recover(row: MeetingTranscription, to: TranscriptState, outcome: RecoveryOutcome)
    async throws
  {
    try await transition(
      meetingID: row.meetingID, to: to, now: outcome.ranAt,
      effects: [
        .setTimestamps(expectedRevision: row.revision),
        .setFailure(category: .finalizationInterrupted, detail: "found=\(row.state.rawValue)"),
      ])
    try await recordOutcome(outcome)
  }
}
