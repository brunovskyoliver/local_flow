import Foundation

/// The meeting domain's view of speaker diarization. Nothing here imports FluidAudio.

enum ModelWorkload: String, Sendable, Equatable {
  case speechRecognition, meetingTranscription, diarization
  /// Feature 010: the voice embedder. Preempted by speech like diarization; never preempts.
  case speakerIdentification

  /// Live and final speech recognition; these preempt the two speaker workloads.
  var isSpeech: Bool { self == .speechRecognition || self == .meetingTranscription }
}

struct DiarizationWindowRequest: Sendable, Equatable {
  static let maxSamples = 9_600_000
  /// Mono 16 kHz, 1...9_600_000 samples, all finite.
  let samples: [Float]
  /// 1 for the default microphone track; nil otherwise.
  let numSpeakers: Int?

  var isValid: Bool {
    (1...Self.maxSamples).contains(samples.count) && (numSpeakers ?? 1) >= 1
      && samples.allSatisfy(\.isFinite)
  }
}

struct DiarizationWindowResult: Sendable, Equatable {
  static let maxTurns = 20_000
  struct Turn: Sendable, Equatable {
    let cluster: Int
    let startSeconds: Double
    let endSeconds: Double
    let quality: Float?
  }
  /// At most 20,000 per window, else `invalidResult`.
  let turns: [Turn]
  /// Cluster → L2-normalized mean embedding. In memory only; never persisted.
  let centroids: [Int: [Float]]

  static let empty = DiarizationWindowResult(turns: [], centroids: [:])

  var isValid: Bool {
    turns.count <= Self.maxTurns
      && turns.allSatisfy {
        $0.cluster >= 0 && $0.startSeconds.isFinite && $0.endSeconds.isFinite
          && $0.startSeconds >= 0 && $0.startSeconds < $0.endSeconds
          && ($0.quality?.isFinite ?? true)
      }
  }
}

protocol DiarizationRuntime: Sendable {
  func diarize(_ request: DiarizationWindowRequest) async throws -> DiarizationWindowResult
  func shutdown() async
}

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
  func meetingWillDelete(id: UUID) async
}
