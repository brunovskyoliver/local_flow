import Foundation
import XCTest

@testable import LocalFlow

/// Scripted diarizer. Window N (1-based) returns `scripts[N-1]`, or the last script
/// once they run out; with no scripts every window is `noSpeech`.
actor FakeDiarizationRuntime: DiarizationRuntime {
  struct Request: Sendable, Equatable {
    let sampleCount: Int
    let numSpeakers: Int?
  }
  struct InjectedFailure: Error, Equatable {}

  private let scripts: [DiarizationWindowResult]
  private(set) var requests: [Request] = []
  private(set) var shutdownCount = 0
  private var failAt: Int?
  private var noSpeechAt: Set<Int> = []
  private var delay: Duration?
  private var gate: PreparationGate?

  init(scripts: [DiarizationWindowResult] = []) { self.scripts = scripts }

  func failWindow(_ index: Int) { failAt = index }
  func noSpeech(onWindow index: Int) { noSpeechAt.insert(index) }
  func setDelay(_ value: Duration?) { delay = value }
  /// The next window blocks inside the runtime until the gate opens, ignoring
  /// cancellation like an uninterruptible Core ML prediction.
  func hold(_ value: PreparationGate) { gate = value }

  func diarize(_ request: DiarizationWindowRequest) async throws -> DiarizationWindowResult {
    requests.append(.init(sampleCount: request.samples.count, numSpeakers: request.numSpeakers))
    let index = requests.count
    if let gate {
      self.gate = nil
      await gate.wait()
    }
    if let delay { try await Task.sleep(for: delay) }
    if failAt == index { throw InjectedFailure() }
    if noSpeechAt.contains(index) || scripts.isEmpty { return .empty }
    return scripts[min(index, scripts.count) - 1]
  }

  func shutdown() { shutdownCount += 1 }
}

/// Counts runtime creations so lifecycle tests can prove when the diarizer loads.
actor FakeDiarizationFactory {
  let runtime: FakeDiarizationRuntime
  private(set) var makeCount = 0
  private var failure: (any Error)?

  init(runtime: FakeDiarizationRuntime = FakeDiarizationRuntime()) { self.runtime = runtime }

  func fail(with error: (any Error)?) { failure = error }

  func make() throws -> any DiarizationRuntime {
    makeCount += 1
    if let failure { throw failure }
    return runtime
  }
}

enum DiarizationScripts {
  /// `(cluster, startSeconds, endSeconds)` turns with no engine quality.
  static func window(
    _ turns: [(Int, Double, Double)], centroids: [Int: [Float]] = [:]
  ) -> DiarizationWindowResult {
    DiarizationWindowResult(
      turns: turns.map { .init(cluster: $0.0, startSeconds: $0.1, endSeconds: $0.2, quality: nil) },
      centroids: centroids)
  }

  /// A unit vector pointing along `axis`; distinct axes are orthogonal speakers.
  static func centroid(axis: Int, dimension: Int = 256) -> [Float] {
    var value = [Float](repeating: 0, count: dimension)
    value[axis % dimension] = 1
    return value
  }

  /// Stretches separated by pauses: each entry is one stretch of tone on both tracks,
  /// `blocks` 4,096-frame blocks long, recorded through the Feature 005 fixture.
  static func stretches(_ blocks: [Int]) -> [TranscriptMeetingFixture.Stretch] {
    blocks.map { .init(microphone: .blocks($0), system: .blocks($0)) }
  }
}

enum DiarizationTestSupport {
  static let identity = DiarizationIdentity(
    engine: "fluidaudio_offline_diarizer", modelID: "FluidInference/speaker-diarization-coreml",
    modelRevision: String(repeating: "1", count: 40),
    manifestHash: String(repeating: "a", count: 64),
    pipelineVersion: DiarizationPipelineVersion.current)

  /// Makes the meeting's transcript `final` with one row per `(startMs, endMs)` span in
  /// stretch 1 and a descriptor recording `stretchLengths`. Returns the pass id.
  @discardableResult
  static func finalTranscript(
    _ transcripts: TranscriptStore, meetingID: UUID, segments: [(Int64, Int64)],
    stretchLengths: [Int64] = [341]
  ) async throws -> UUID {
    let row = try await transcripts.transcription(meetingID: meetingID)
    if row?.state == .notRequested {
      try await transcripts.transition(meetingID: meetingID, to: .pending, now: 1, effects: [])
    }
    let pass = UUID()
    try await transcripts.transition(
      meetingID: meetingID, to: .finalizing, now: 2, effects: [.setPass(id: pass, kind: .final)])
    var bases: [Int64] = []
    var base: Int64 = 0
    for length in stretchLengths {
      bases.append(base)
      base += length
    }
    let covered = max(base, segments.map(\.1).max() ?? 0)
    let drafts = segments.enumerated().map { ordinal, span in
      let stretch = (bases.lastIndex { $0 <= span.0 } ?? 0) + 1
      return TranscriptSegmentDraft(
        finality: .final, ordinal: ordinal, stretchSequence: stretch, startMs: span.0,
        endMs: span.1, coveredMs: covered, windowIndex: 0, timingBasis: .window,
        rawText: "words \(ordinal)", assembledText: "words \(ordinal)",
        normalizedText: "Words \(ordinal).", analysisTracks: .both)
    }
    for start in stride(from: 0, to: drafts.count, by: 50) {
      _ = try await transcripts.appendSegments(
        meetingID: meetingID, passID: pass,
        drafts: Array(drafts[start..<min(start + 50, drafts.count)]),
        progress: nil, now: 3)
    }
    let descriptor = AnalysisStreamDescriptor(
      source: .decodedTracks, contributingTracks: [.mic, .system],
      stretches: stretchLengths.enumerated().map {
        .init(sequence: $0.offset + 1, lengthMs: $0.element, tracks: .both)
      })
    _ = try await transcripts.completeFinalPass(
      meetingID: meetingID, passID: pass, descriptor: descriptor, coveredMs: covered, now: 4)
    return pass
  }

  /// Polls on the main actor until `condition` holds or two seconds pass.
  @MainActor
  static func eventually(
    _ condition: @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line
  ) async {
    for _ in 0..<400 {
      if await condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("condition not met", file: file, line: line)
  }
}

/// In-memory `SpeakerStoring` for the Assign speakers model: serves scripted
/// summaries and suggestions and records every write. Run operations are unsupported.
actor FakeSpeakerStore: SpeakerStoring {
  struct Unsupported: Error {}

  var summaries: [SpeakerSummary] = []
  var names: [String] = []
  var saveError: (any Error)?
  private(set) var savedNames: [[UUID: String?]] = []
  private(set) var suggestionQueries: [(prefix: String, limit: Int)] = []
  private(set) var merges: [(speaker: UUID, target: UUID)] = []
  private(set) var unmerges: [UUID] = []
  private(set) var corrections: [(segment: UUID, correction: SegmentCorrection)] = []

  init(summaries: [SpeakerSummary] = [], names: [String] = []) {
    self.summaries = summaries
    self.names = names
  }

  func setSummaries(_ value: [SpeakerSummary]) { summaries = value }
  func setNames(_ value: [String]) { names = value }
  func failSaves(with error: (any Error)?) { saveError = error }

  func speakerSummaries(meetingID: UUID) throws -> [SpeakerSummary] { summaries }

  func saveNames(meetingID: UUID, names: [UUID: String?], now: Int64) throws {
    if let saveError { throw saveError }
    savedNames.append(names)
    summaries = summaries.map { summary in
      guard let name = names[summary.id] else { return summary }
      return SpeakerSummary(
        id: summary.id, source: summary.source, labelOrdinal: summary.labelOrdinal,
        colorIndex: summary.colorIndex, displayName: name, inRoom: summary.inRoom,
        speechMs: summary.speechMs, quotes: summary.quotes)
    }
  }

  func nameSuggestions(prefix: String, limit: Int) throws -> [String] {
    suggestionQueries.append((prefix, limit))
    return Array(names.filter { $0.hasPrefix(prefix) }.prefix(limit))
  }

  /// Moves the speaker's section under the target as "Includes …".
  func merge(meetingID: UUID, speakerID: UUID, into targetID: UUID, now: Int64) throws {
    if let saveError { throw saveError }
    merges.append((speakerID, targetID))
    guard let moved = summaries.first(where: { $0.id == speakerID }),
      let index = summaries.firstIndex(where: { $0.id == targetID })
    else { throw Unsupported() }
    summaries[index].includes.append(
      .init(
        id: moved.id, source: moved.source, labelOrdinal: moved.labelOrdinal, inRoom: moved.inRoom))
    summaries[index].includes += moved.includes
    summaries.removeAll { $0.id == speakerID }
  }

  func unmerge(meetingID: UUID, speakerID: UUID, now: Int64) throws {
    if let saveError { throw saveError }
    unmerges.append(speakerID)
    for index in summaries.indices {
      guard let member = summaries[index].includes.first(where: { $0.id == speakerID }) else {
        continue
      }
      summaries[index].includes.removeAll { $0.id == speakerID }
      summaries.append(
        SpeakerSummary(
          id: member.id, source: member.source, labelOrdinal: member.labelOrdinal,
          colorIndex: summaries.count % 8, displayName: nil, inRoom: member.inRoom, speechMs: 1))
      return
    }
    throw Unsupported()
  }

  private(set) var inRoom: [UUID: Bool] = [:]
  func setInRoom(meetingID: UUID, inRoom value: Bool, now: Int64) throws {
    inRoom[meetingID] = value
  }

  var reviews: [ReviewNotice] = []
  private(set) var dismissed: [UUID] = []

  func setReviews(_ value: [ReviewNotice]) { reviews = value }
  func reviewNotices(meetingID: UUID) throws -> [ReviewNotice] { reviews }
  func dismissReview(id: UUID) throws {
    if let saveError { throw saveError }
    dismissed.append(id)
    reviews.removeAll { $0.id == id }
  }

  func correctSegment(
    meetingID: UUID, segmentID: UUID, to correction: SegmentCorrection, now: Int64
  ) throws -> UUID? {
    corrections.append((segmentID, correction))
    if case .speaker(let id) = correction { return id }
    return correction == .newSpeaker ? UUID() : nil
  }

  func diarization(meetingID: UUID) throws -> MeetingDiarization? { nil }
  func admit(
    meetingID: UUID, transcriptPassID: UUID, trigger: DiarizationTrigger,
    identity: DiarizationIdentity, expectedRevision: Int64?, now: Int64
  ) throws -> DiarizationRun { throw Unsupported() }
  func start(runID: UUID, now: Int64) throws -> DiarizationRun { throw Unsupported() }
  func appendWindow(runID: UUID, speakers: [SpeakerDraft], turns: [TurnDraft], audioMs: Int64)
    throws
  { throw Unsupported() }
  func complete(runID: UUID, assignments: [AssignmentDraft], now: Int64) throws -> DiarizationRun {
    throw Unsupported()
  }
  func fail(runID: UUID, category: DiarizationFailureCategory, detail: String?, now: Int64) throws {
    throw Unsupported()
  }
  func interrupt(runID: UUID, now: Int64) throws { throw Unsupported() }
  func requeue(runID: UUID) throws { throw Unsupported() }
  func cancel(runID: UUID) throws { throw Unsupported() }
  func run(id: UUID) throws -> DiarizationRun? { nil }
  func meetingState(meetingID: UUID) throws -> MeetingDiarizationState { .notRequested }
  func latestRun(meetingID: UUID) throws -> DiarizationRun? { nil }
  func activeRuns(limit: Int) throws -> [DiarizationRun] { [] }
  func turns(runID: UUID, overlapping range: Range<Int64>, after cursor: TurnCursor?, limit: Int)
    throws -> [SpeakerTurn]
  { [] }
}

/// The real store with one injected failure, for the persistence categories.
actor FailingSpeakerStore: SpeakerStoring {
  private let store: SpeakerStore
  private var appendWindowError: (any Error)?
  private var completeError: (any Error)?

  init(_ store: SpeakerStore) { self.store = store }

  func failAppendWindow(with error: any Error) { appendWindowError = error }
  func failComplete(with error: any Error) { completeError = error }

  func appendWindow(runID: UUID, speakers: [SpeakerDraft], turns: [TurnDraft], audioMs: Int64)
    async throws
  {
    if let appendWindowError { throw appendWindowError }
    try await store.appendWindow(runID: runID, speakers: speakers, turns: turns, audioMs: audioMs)
  }
  func complete(runID: UUID, assignments: [AssignmentDraft], now: Int64) async throws
    -> DiarizationRun
  {
    if let completeError { throw completeError }
    return try await store.complete(runID: runID, assignments: assignments, now: now)
  }

  func diarization(meetingID: UUID) async throws -> MeetingDiarization? {
    try await store.diarization(meetingID: meetingID)
  }
  func admit(
    meetingID: UUID, transcriptPassID: UUID, trigger: DiarizationTrigger,
    identity: DiarizationIdentity, expectedRevision: Int64?, now: Int64
  ) async throws -> DiarizationRun {
    try await store.admit(
      meetingID: meetingID, transcriptPassID: transcriptPassID, trigger: trigger,
      identity: identity, expectedRevision: expectedRevision, now: now)
  }
  func start(runID: UUID, now: Int64) async throws -> DiarizationRun {
    try await store.start(runID: runID, now: now)
  }
  func fail(runID: UUID, category: DiarizationFailureCategory, detail: String?, now: Int64)
    async throws
  {
    try await store.fail(runID: runID, category: category, detail: detail, now: now)
  }
  func interrupt(runID: UUID, now: Int64) async throws {
    try await store.interrupt(runID: runID, now: now)
  }
  func requeue(runID: UUID) async throws { try await store.requeue(runID: runID) }
  func cancel(runID: UUID) async throws { try await store.cancel(runID: runID) }
  func run(id: UUID) async throws -> DiarizationRun? { try await store.run(id: id) }
  func meetingState(meetingID: UUID) async throws -> MeetingDiarizationState {
    try await store.meetingState(meetingID: meetingID)
  }
  func latestRun(meetingID: UUID) async throws -> DiarizationRun? {
    try await store.latestRun(meetingID: meetingID)
  }
  func activeRuns(limit: Int) async throws -> [DiarizationRun] {
    try await store.activeRuns(limit: limit)
  }
  func turns(runID: UUID, overlapping range: Range<Int64>, after cursor: TurnCursor?, limit: Int)
    async throws -> [SpeakerTurn]
  {
    try await store.turns(runID: runID, overlapping: range, after: cursor, limit: limit)
  }
  func speakerSummaries(meetingID: UUID) async throws -> [SpeakerSummary] {
    try await store.speakerSummaries(meetingID: meetingID)
  }
  func saveNames(meetingID: UUID, names: [UUID: String?], now: Int64) async throws {
    try await store.saveNames(meetingID: meetingID, names: names, now: now)
  }
  func nameSuggestions(prefix: String, limit: Int) async throws -> [String] {
    try await store.nameSuggestions(prefix: prefix, limit: limit)
  }
  func merge(meetingID: UUID, speakerID: UUID, into targetID: UUID, now: Int64) async throws {
    try await store.merge(meetingID: meetingID, speakerID: speakerID, into: targetID, now: now)
  }
  func unmerge(meetingID: UUID, speakerID: UUID, now: Int64) async throws {
    try await store.unmerge(meetingID: meetingID, speakerID: speakerID, now: now)
  }
  func correctSegment(
    meetingID: UUID, segmentID: UUID, to correction: SegmentCorrection, now: Int64
  ) async throws -> UUID? {
    try await store.correctSegment(
      meetingID: meetingID, segmentID: segmentID, to: correction, now: now)
  }
  func setInRoom(meetingID: UUID, inRoom: Bool, now: Int64) async throws {
    try await store.setInRoom(meetingID: meetingID, inRoom: inRoom, now: now)
  }
  func reviewNotices(meetingID: UUID) async throws -> [ReviewNotice] {
    try await store.reviewNotices(meetingID: meetingID)
  }
  func dismissReview(id: UUID) async throws { try await store.dismissReview(id: id) }
}
