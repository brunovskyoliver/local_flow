import Foundation
import GRDB
import XCTest

@testable import LocalFlow

/// Scripted voice embedder. Region N (1-based) returns `scripts[N-1]`, or the last
/// script once they run out; with no scripts every region is `noSpeech`.
actor FakeVoiceEmbeddingRuntime: VoiceEmbeddingRuntime {
  struct InjectedFailure: Error, Equatable {}

  private var scripts: [[Float]]
  /// Sample counts of every request, in order.
  private(set) var requests: [Int] = []
  private(set) var shutdownCount = 0
  private var failAt: Int?
  private var noSpeechAt: Set<Int> = []
  private var delay: Duration?
  private var gate: PreparationGate?
  /// Vectors are handed out in call order; a scripted speaker map returns the same
  /// vector for every region of one cluster when `perRegion` is nil.
  init(scripts: [[Float]] = []) { self.scripts = scripts }

  func setScripts(_ value: [[Float]]) { scripts = value }
  func failRegion(_ index: Int) { failAt = index }
  func noSpeech(onRegion index: Int) { noSpeechAt.insert(index) }
  func setDelay(_ value: Duration?) { delay = value }
  /// The next region blocks inside the runtime until the gate opens, ignoring
  /// cancellation like an uninterruptible Core ML prediction.
  func hold(_ value: PreparationGate) { gate = value }

  func embed(_ request: VoiceRegionRequest) async throws -> VoiceEmbedding {
    requests.append(request.samples.count)
    let index = requests.count
    if let gate {
      self.gate = nil
      await gate.wait()
    }
    if let delay { try await Task.sleep(for: delay) }
    if failAt == index { throw InjectedFailure() }
    if noSpeechAt.contains(index) || scripts.isEmpty { throw VoiceEmbeddingFailure.noSpeech }
    let vector = scripts[min(index, scripts.count) - 1]
    return VoiceEmbedding(
      vector: vector, speechSeconds: Double(request.samples.count) / 16_000)
  }

  func shutdown() { shutdownCount += 1 }
}

/// Counts runtime creations so lifecycle tests can prove when the embedder loads.
actor FakeVoiceEmbeddingFactory {
  let runtime: FakeVoiceEmbeddingRuntime
  private(set) var makeCount = 0
  private var failure: (any Error)?

  init(runtime: FakeVoiceEmbeddingRuntime = FakeVoiceEmbeddingRuntime()) {
    self.runtime = runtime
  }

  func fail(with error: (any Error)?) { failure = error }

  func make() throws -> any VoiceEmbeddingRuntime {
    makeCount += 1
    if let failure { throw failure }
    return runtime
  }
}

enum VoiceVectors {
  static let dimension = VoiceEmbedding.dimension

  /// A unit vector along `axis`; distinct axes are orthogonal (cosine 0).
  static func unit(axis: Int) -> [Float] {
    var value = [Float](repeating: 0, count: dimension)
    value[axis % dimension] = 1
    return value
  }

  /// A unit vector whose cosine with `unit(axis:)` is exactly `cosine`, tilted toward
  /// `other`; same-person fixtures use 0.8–0.95, different-person 0.2–0.5.
  static func related(axis: Int, other: Int, cosine: Float) -> [Float] {
    precondition(axis != other)
    var value = [Float](repeating: 0, count: dimension)
    value[axis % dimension] = cosine
    value[other % dimension] = (1 - cosine * cosine).squareRoot()
    return value
  }

  static func normalized(_ raw: [Float]) -> [Float] {
    let norm = raw.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
    return raw.map { $0 / norm }
  }
}

enum IdentificationTestSupport {
  static let identity = VoiceModelIdentity(
    engine: IdentificationThresholds.wespeakerEngine,
    modelID: "FluidInference/speaker-diarization-coreml",
    modelRevision: String(repeating: "1", count: 40),
    manifestHash: String(repeating: "a", count: 64), dimension: VoiceEmbedding.dimension)

  static var thresholds: IdentificationThresholds {
    IdentificationThresholds.current(for: identity)!
  }

  static func draft(
    vector: [Float], meetingID: UUID, speakerID: UUID, track: MeetingTrackKind = .system,
    startMs: Int64 = 0, endMs: Int64 = 8_000, quality: Double = 0.8,
    identity: VoiceModelIdentity = identity
  ) -> VoiceSampleDraft {
    VoiceSampleDraft(
      vector: vector, identity: identity, pipelineVersion: IdentificationPipelineVersion.current,
      qualityLabel: VoiceRegionSelector.qualityLabel(
        durationMs: endMs - startMs, engineQuality: nil),
      qualityScore: quality, engineQuality: nil, speechMs: endMs - startMs, track: track,
      startMs: startMs, endMs: endMs, sourceMeetingID: meetingID, sourceSpeakerID: speakerID)
  }

  /// A finalized fixture meeting with an accepted diarization run: one local cluster
  /// on the microphone and `remote` remote clusters on the system track, each with the
  /// given turns `(startMs, endMs)` on the recorded timeline. Turns of different
  /// clusters must not intersect unless the test wants them overlapped. Returns the
  /// run and the cluster ids in cluster order (local first).
  @discardableResult
  static func acceptedDiarization(
    _ fixture: MeetingTestStore, transcripts: TranscriptStore, speakers: SpeakerStore,
    meetingID: UUID, local: [(Int64, Int64)] = [(100, 5_000)],
    remote: [[(Int64, Int64)]] = [[(6_000, 14_000)]], quality: Float? = nil,
    segments: [(Int64, Int64)]? = nil, stretchLengths: [Int64] = [60_000]
  ) async throws -> (run: DiarizationRun, clusters: [UUID]) {
    let spans = segments ?? (local + remote.flatMap { $0 }).sorted { $0.0 < $1.0 }
    let pass = try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: meetingID, segments: spans, stretchLengths: stretchLengths)
    let run = try await speakers.admit(
      meetingID: meetingID, transcriptPassID: pass, trigger: .manual,
      identity: DiarizationTestSupport.identity, expectedRevision: nil, now: 10)
    _ = try await speakers.start(runID: run.id, now: 11)
    var drafts: [SpeakerDraft] = []
    var turns: [TurnDraft] = []
    var ids: [UUID] = []
    let localID = UUID()
    ids.append(localID)
    drafts.append(
      .init(id: localID, clusterKey: 0, track: .microphone, reconciliation: .confident))
    for (start, end) in local {
      turns.append(
        .init(speakerID: localID, track: .microphone, startMs: start, endMs: end, quality: quality))
    }
    for (index, cluster) in remote.enumerated() {
      let id = UUID()
      ids.append(id)
      drafts.append(
        .init(id: id, clusterKey: index + 1, track: .system, reconciliation: .confident))
      for (start, end) in cluster {
        turns.append(
          .init(speakerID: id, track: .system, startMs: start, endMs: end, quality: quality))
      }
    }
    try await speakers.appendWindow(
      runID: run.id, speakers: drafts, turns: turns, audioMs: stretchLengths.reduce(0, +))
    // Every segment is aligned to the cluster whose turn covers it.
    let page = try await transcripts.page(
      meetingID: meetingID, finality: .final, after: nil, limit: 200)
    let assignments = page.map { segment -> AssignmentDraft in
      let owner = turns.first { $0.startMs <= segment.startMs && $0.endMs >= segment.endMs }
      return AssignmentDraft(
        segmentID: segment.id, kind: owner == nil ? .unknown : .speaker,
        speakerID: owner?.speakerID, topSpeakerID: owner?.speakerID, secondSpeakerID: nil,
        topCoverage: owner == nil ? 0 : 1, secondCoverage: 0)
    }
    let completed = try await speakers.complete(runID: run.id, assignments: assignments, now: 12)
    return (completed, ids)
  }

  /// A SHA-256 over every row of the given tables, for byte-identity checks.
  static func digest(_ database: some DatabaseReader, tables: [String]) throws -> String {
    try database.read { db in
      var text = ""
      for table in tables {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY 1, 2")
        for row in rows { text += row.description + "\n" }
      }
      return TranscriptionQualityDetail.hash(Data(text.utf8))
    }
  }

  static let preservedTables = [
    "transcript_segments", "speaker_turns", "speaker_assignments", "meeting_speakers",
    "meeting_segments", "meeting_tracks",
  ]
}

/// In-memory `IdentityStoring` for view models and coordinators: scripted rows and a
/// record of every write. Run operations keep a small state machine so the coordinator
/// can be exercised without a database.
actor FakeIdentityStore: IdentityStoring {
  struct Unsupported: Error {}
  struct Call: Equatable, Sendable {
    let name: String
    let ids: [UUID]
  }

  var known: [KnownSpeakerRow] = []
  var sampleRows: [UUID: [VoiceSampleRow]] = [:]
  var identityRows: [UUID: [UUID: SpeakerIdentity]] = [:]
  var compatibleProfiles: [CandidateProfile] = []
  var unknownMeetings: [UUID] = []
  var runs: [UUID: IdentificationRun] = [:]
  var meetings: [UUID: MeetingIdentification] = [:]
  var failure: (any Error)?
  private(set) var calls: [Call] = []
  private(set) var addedSamples:
    [(knownSpeakerID: UUID, drafts: [VoiceSampleDraft], consent: SampleConsent)] = []
  private(set) var candidates: [UUID: [MatchCandidateDraft]] = [:]
  private(set) var completed: [(runID: UUID, decisions: [UUID: IdentityMatcher.Decision])] = []

  init(known: [KnownSpeakerRow] = []) { self.known = known }

  func setKnown(_ value: [KnownSpeakerRow]) { known = value }
  func setSamples(_ value: [VoiceSampleRow], for id: UUID) { sampleRows[id] = value }
  func setIdentities(_ value: [UUID: SpeakerIdentity], for meetingID: UUID) {
    identityRows[meetingID] = value
  }
  func setProfiles(_ value: [CandidateProfile]) { compatibleProfiles = value }
  func setUnknownMeetings(_ value: [UUID]) { unknownMeetings = value }
  func fail(with error: (any Error)?) { failure = error }
  func setMeeting(_ meetingID: UUID) {
    meetings[meetingID] = MeetingIdentification(meetingID: meetingID, updatedAt: 0)
  }

  private func record(_ name: String, _ ids: UUID...) throws {
    calls.append(Call(name: name, ids: ids))
    if let failure { throw failure }
  }

  func knownSpeakers() throws -> [KnownSpeakerRow] {
    try record("knownSpeakers")
    return known
  }

  func createKnownSpeaker(name: String, isLocalUser: Bool, now: Int64) throws -> KnownSpeakerRow {
    try record("createKnownSpeaker")
    let row = KnownSpeakerRow(
      id: UUID(), name: name, activeSampleCount: 0, recognitionEnabled: true,
      state: .needsReenrollment, isLocalUser: isLocalUser, revision: 0, createdAt: now)
    known.append(row)
    return row
  }

  func enroll(
    meetingID: UUID, speakerID: UUID?, name: String, isLocalUser: Bool, origin: IdentityOrigin,
    now: Int64
  ) throws -> KnownSpeakerRow {
    try record("enroll", meetingID)
    let row = try createKnownSpeaker(name: name, isLocalUser: isLocalUser, now: now)
    if let speakerID {
      identityRows[meetingID, default: [:]][speakerID] = SpeakerIdentity(
        state: .confirmed, origin: origin, knownSpeakerID: row.id, knownSpeakerName: name)
    }
    return row
  }

  func rename(knownSpeakerID: UUID, to name: String, expectedRevision: Int64, now: Int64) throws {
    try record("rename", knownSpeakerID)
    guard let index = known.firstIndex(where: { $0.id == knownSpeakerID }) else {
      throw IdentityStore.Error.missingRow
    }
    guard known[index].revision == expectedRevision else {
      throw IdentityStore.Error.revisionMismatch
    }
    let old = known[index]
    known[index] = KnownSpeakerRow(
      id: old.id, name: name, activeSampleCount: old.activeSampleCount,
      recognitionEnabled: old.recognitionEnabled, state: old.state, isLocalUser: old.isLocalUser,
      revision: old.revision + 1, createdAt: old.createdAt)
  }

  func setRecognition(knownSpeakerID: UUID, enabled: Bool, expectedRevision: Int64, now: Int64)
    throws
  {
    try record("setRecognition", knownSpeakerID)
    guard let index = known.firstIndex(where: { $0.id == knownSpeakerID }) else {
      throw IdentityStore.Error.missingRow
    }
    guard known[index].revision == expectedRevision else {
      throw IdentityStore.Error.revisionMismatch
    }
    let old = known[index]
    known[index] = KnownSpeakerRow(
      id: old.id, name: old.name, activeSampleCount: old.activeSampleCount,
      recognitionEnabled: enabled, state: old.state, isLocalUser: old.isLocalUser,
      revision: old.revision + 1, createdAt: old.createdAt)
  }

  func deleteKnownSpeaker(id: UUID, expectedRevision: Int64) throws {
    try record("deleteKnownSpeaker", id)
    guard let index = known.firstIndex(where: { $0.id == id }) else {
      throw IdentityStore.Error.missingRow
    }
    guard known[index].revision == expectedRevision else {
      throw IdentityStore.Error.revisionMismatch
    }
    known.remove(at: index)
    sampleRows[id] = nil
  }

  func samples(knownSpeakerID: UUID) throws -> [VoiceSampleRow] {
    try record("samples", knownSpeakerID)
    return sampleRows[knownSpeakerID] ?? []
  }

  func removeSample(id: UUID, now: Int64) throws {
    try record("removeSample", id)
    for key in sampleRows.keys { sampleRows[key]?.removeAll { $0.id == id } }
  }

  func addSamples(
    knownSpeakerID: UUID, drafts: [VoiceSampleDraft], consent: SampleConsent, now: Int64
  ) throws -> Int {
    try record("addSamples", knownSpeakerID)
    addedSamples.append((knownSpeakerID, drafts, consent))
    return drafts.count
  }

  func profiles(compatibleWith identity: VoiceModelIdentity) throws -> [CandidateProfile] {
    try record("profiles")
    return compatibleProfiles
  }

  func identification(meetingID: UUID) throws -> MeetingIdentification? {
    meetings[meetingID]
  }

  func admit(
    meetingID: UUID, trigger: IdentificationTrigger, identity: VoiceModelIdentity, policy: String,
    now: Int64
  ) throws -> IdentificationRun {
    try record("admit", meetingID)
    guard meetings[meetingID] != nil else { throw IdentityStore.Error.missingRow }
    if runs.values.contains(where: {
      $0.meetingID == meetingID && ($0.state == .pending || $0.state == .running)
    }) {
      throw IdentityStore.Error.runInProgress
    }
    let run = IdentificationRun(
      id: UUID(), meetingID: meetingID, diarizationRunID: UUID(), state: .pending,
      trigger: trigger, identity: identity, pipelineVersion: "test", thresholdPolicy: policy,
      createdAt: now)
    runs[run.id] = run
    meetings[meetingID]?.currentRunID = run.id
    return run
  }

  func run(id: UUID) throws -> IdentificationRun? { runs[id] }

  func start(runID: UUID, now: Int64) throws -> IdentificationRun {
    try record("start", runID)
    guard var run = runs[runID] else { throw IdentityStore.Error.missingRow }
    run.state = .running
    run.startedAt = now
    runs[runID] = run
    return run
  }

  func appendCandidates(runID: UUID, rows: [MatchCandidateDraft]) throws {
    try record("appendCandidates", runID)
    candidates[runID, default: []] += rows
  }

  func complete(runID: UUID, decisions: [UUID: IdentityMatcher.Decision], now: Int64) throws
    -> IdentificationRun
  {
    try record("complete", runID)
    guard var run = runs[runID] else { throw IdentityStore.Error.missingRow }
    run.state = .succeeded
    run.completedAt = now
    runs[runID] = run
    completed.append((runID, decisions))
    meetings[run.meetingID]?.acceptedRunID = runID
    meetings[run.meetingID]?.currentRunID = nil
    return run
  }

  func fail(runID: UUID, category: IdentificationFailureCategory, detail: String?, now: Int64)
    throws
  {
    try record("fail", runID)
    guard var run = runs[runID] else { throw IdentityStore.Error.missingRow }
    run.state = .failed
    run.failureCategory = category
    runs[runID] = run
    meetings[run.meetingID]?.currentRunID = nil
  }

  func interrupt(runID: UUID, now: Int64) throws {
    try record("interrupt", runID)
    guard var run = runs[runID] else { throw IdentityStore.Error.missingRow }
    run.state = .interrupted
    run.failureCategory = .interrupted
    runs[runID] = run
    meetings[run.meetingID]?.currentRunID = nil
  }

  func requeue(runID: UUID) throws {
    try record("requeue", runID)
    guard var run = runs[runID] else { throw IdentityStore.Error.missingRow }
    run.state = .pending
    run.preemptionCount += 1
    runs[runID] = run
  }

  func cancel(runID: UUID) throws {
    try record("cancel", runID)
    guard let run = runs[runID] else { throw IdentityStore.Error.missingRow }
    runs[runID] = nil
    meetings[run.meetingID]?.currentRunID = nil
  }

  func activeRuns(limit: Int) throws -> [IdentificationRun] {
    Array(
      runs.values.filter { $0.state == .pending || $0.state == .running }
        .sorted { $0.createdAt < $1.createdAt }.prefix(limit))
  }

  func latestRun(meetingID: UUID) throws -> IdentificationRun? {
    runs.values.filter { $0.meetingID == meetingID && $0.state != .superseded }
      .max { $0.createdAt < $1.createdAt }
  }

  func meetingState(meetingID: UUID) throws -> MeetingIdentificationState {
    let current = meetings[meetingID]?.currentRunID.flatMap { runs[$0] }?.state
    let latest = try latestRun(meetingID: meetingID)?.state
    return IdentificationRunLifecycle.meetingState(
      current: current, latest: latest, hasAccepted: meetings[meetingID]?.acceptedRunID != nil)
  }

  func meetingsWithUnknownRemoteSpeakers(limit: Int) throws -> [UUID] {
    try record("meetingsWithUnknownRemoteSpeakers")
    return Array(unknownMeetings.prefix(limit))
  }

  func identities(meetingID: UUID) throws -> [UUID: SpeakerIdentity] {
    try record("identities", meetingID)
    return identityRows[meetingID] ?? [:]
  }

  var rejectedPairs: [UUID: Set<UUID>] = [:]
  func setRejected(_ value: [UUID: Set<UUID>]) { rejectedPairs = value }
  func rejectedCandidates(meetingID: UUID) throws -> [UUID: Set<UUID>] { rejectedPairs }

  private(set) var regionCounts: [UUID: (Int, Int)] = [:]
  func recordRegions(runID: UUID, extracted: Int, rejected: Int) throws {
    try record("recordRegions", runID)
    regionCounts[runID] = (extracted, rejected)
    runs[runID]?.regionCount = extracted
    runs[runID]?.rejectedRegionCount = rejected
  }

  func link(
    meetingID: UUID, speakerID: UUID, to knownSpeakerID: UUID, origin: IdentityOrigin, now: Int64
  ) throws {
    try record("link:\(origin.rawValue)", meetingID, speakerID, knownSpeakerID)
    let name = known.first { $0.id == knownSpeakerID }?.name
    identityRows[meetingID, default: [:]][speakerID] = SpeakerIdentity(
      state: .confirmed, origin: origin, knownSpeakerID: knownSpeakerID, knownSpeakerName: name)
  }

  func reject(
    meetingID: UUID, speakerID: UUID, candidate knownSpeakerID: UUID, keepUnknown: Bool, now: Int64
  ) throws {
    try record("reject:\(keepUnknown)", meetingID, speakerID, knownSpeakerID)
    if keepUnknown {
      identityRows[meetingID, default: [:]][speakerID] = SpeakerIdentity(
        state: .rejectedUnknown, origin: .keptUnknown)
    }
  }

  func resolveMerged(meetingID: UUID, rootID: UUID, to resolution: MergedResolution, now: Int64)
    throws
  {
    switch resolution {
    case .knownSpeaker(let id): try record("resolveMerged:known", meetingID, rootID, id)
    case .keepUnknown: try record("resolveMerged:unknown", meetingID, rootID)
    }
  }

  func clearMergedResolution(meetingID: UUID, rootID: UUID) throws {
    try record("clearMergedResolution", meetingID, rootID)
  }

  func unlink(meetingID: UUID, speakerID: UUID, now: Int64) throws {
    try record("unlink", meetingID, speakerID)
    identityRows[meetingID, default: [:]][speakerID] = SpeakerIdentity(
      state: .unknown, origin: .keptUnknown)
  }
}
