import Foundation
import XCTest

@testable import LocalFlow

// MARK: - Fixture loading

/// One `fixtures/intelligence/*.json` meeting, decoded into the evidence types.
struct IntelligenceFixture {
  let id: UUID
  let title: String
  let startedAt: String
  let durationMs: Int64
  let timeZone: String
  let expectedLanguage: String?
  let expectedTerms: [String]
  var participants: [EvidenceParticipant]
  /// `candidate_name_kept_local` by speaker id; must never reach the wire.
  var candidateNames: [UUID: String]
  var segments: [EvidenceSegment]
  var notes: [NoteParagraph]

  var meeting: Meeting {
    Meeting(
      id: id, state: .completed, title: title, createdAt: 0, startedAt: 0,
      stoppedAt: durationMs, completedAt: durationMs, wallClockMs: durationMs,
      recordedMs: durationMs, finalizationStage: nil, failureReason: nil,
      failureDetail: nil, updatedAt: durationMs, revision: 1)
  }
}

enum IntelligenceFixtures {
  static var root: URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }

  static func meeting(_ name: String) throws -> IntelligenceFixture {
    if name == "fourhour" { return fourHourMeeting() }
    let url = root.appendingPathComponent("fixtures/intelligence/\(name).json")
    let data = try Data(contentsOf: url)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any],
      "fixture \(name) is not an object")
    return try decodeMeeting(object, name: name)
  }

  /// One `responses/<name>.json` file: stage → list of streams, each stream a
  /// list of line objects (`{"$raw": "…"}` stays a raw string).
  static func response(_ name: String) throws -> [AnalysisStage: [[Any]]] {
    let url = root.appendingPathComponent(
      "fixtures/intelligence/responses/\(name).json")
    let data = try Data(contentsOf: url)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any],
      "response \(name) is not an object")
    let streams = try XCTUnwrap(object["streams"] as? [String: Any])
    var out: [AnalysisStage: [[Any]]] = [:]
    for (key, value) in streams {
      guard let stage = AnalysisStage(rawValue: key),
        let streamList = value as? [[Any]]
      else { continue }
      out[stage] = streamList
    }
    return out
  }

  private static func decodeMeeting(
    _ object: [String: Any], name: String
  ) throws -> IntelligenceFixture {
    let id = try XCTUnwrap(
      UUID(uuidString: try XCTUnwrap(object["id"] as? String)))
    var participants: [EvidenceParticipant] = []
    var candidateNames: [UUID: String] = [:]
    for raw in object["participants"] as? [[String: Any]] ?? [] {
      let speakerID = try XCTUnwrap(
        UUID(uuidString: try XCTUnwrap(raw["speaker_id"] as? String)))
      var participant = EvidenceParticipant(
        speakerID: speakerID,
        certainty: ParticipantCertainty(
          rawValue: try XCTUnwrap(raw["certainty"] as? String)) ?? .unknown,
        origin: raw["origin"] as? String ?? "none",
        knownSpeakerID: (raw["known_speaker_id"] as? String).flatMap(UUID.init),
        name: raw["name"] as? String)
      participant.isLocalUser = participant.certainty == .localUser
      participants.append(participant)
      if let candidate = raw["candidate_name_kept_local"] as? String {
        candidateNames[speakerID] = candidate
      }
    }
    var segments: [EvidenceSegment] = []
    for raw in object["segments"] as? [[String: Any]] ?? [] {
      let speaker: EffectiveSpeaker
      if let rawID = raw["speaker_id"] as? String, let id = UUID(uuidString: rawID) {
        speaker = .speaker(id)
      } else {
        speaker = (raw["speaker"] as? String) == "ambiguous" ? .ambiguous : .unknown
      }
      segments.append(
        EvidenceSegment(
          id: try XCTUnwrap(
            UUID(uuidString: try XCTUnwrap(raw["id"] as? String))),
          ordinal: raw["ordinal"] as? Int ?? segments.count,
          startMs: Int64(raw["start_ms"] as? Int ?? 0),
          endMs: Int64(raw["end_ms"] as? Int ?? 0),
          speaker: speaker,
          text: try XCTUnwrap(raw["normalized_text"] as? String)))
    }
    var notes: [NoteParagraph] = []
    let noteText = object["notes"] as? String ?? ""
    for (index, paragraph) in noteText.components(separatedBy: "\n\n").enumerated()
    where !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
      notes.append(
        NoteParagraph(
          ordinal: index + 1, text: trimmed,
          hash: EvidenceVersion.hash(paragraph: trimmed)))
    }
    return IntelligenceFixture(
      id: id, title: object["title"] as? String ?? "Fixture",
      startedAt: object["started_at"] as? String ?? "2026-09-20T09:00:00Z",
      durationMs: Int64(object["duration_ms"] as? Int ?? 0),
      timeZone: object["time_zone"] as? String ?? "UTC",
      expectedLanguage: object["expected_language"] as? String,
      expectedTerms: object["expected_terms"] as? [String] ?? [],
      participants: participants, candidateNames: candidateNames,
      segments: segments, notes: notes)
  }

  /// The deterministic four-hour fixture documented in README.md: ~200 KB of
  /// segment text, the decision "Deployment moves to Monday" in the last five
  /// minutes.
  static func fourHourMeeting() -> IntelligenceFixture {
    var segments: [EvidenceSegment] = []
    let filler = "The group discussed the release checklist and open work. "
    var offset: Int64 = 0
    var ordinal = 0
    var bytes = 0
    while bytes < 200_000 {
      let text = filler + "Topic \(ordinal) covered in detail."
      segments.append(
        EvidenceSegment(
          id: UUID(
            uuidString: String(
              format: "f0000000-0000-4000-8000-%012d", ordinal))!,
          ordinal: ordinal, startMs: offset, endMs: offset + 12_000,
          speaker: .speaker(
            UUID(uuidString: "f000aa00-0000-4000-8000-000000000000")!),
          text: text))
      offset += 12_000
      bytes += text.utf8.count
      ordinal += 1
    }
    let durationMs: Int64 = 4 * 3_600_000
    segments.append(
      EvidenceSegment(
        id: UUID(uuidString: "f0000000-0000-4000-8000-fffffffffffe")!,
        ordinal: ordinal, startMs: durationMs - 300_000,
        endMs: durationMs - 290_000,
        speaker: .speaker(
          UUID(uuidString: "f000aa00-0000-4000-8000-000000000000")!),
        text: "So we agree: deployment moves to Monday."))
    return IntelligenceFixture(
      id: UUID(uuidString: "11111111-1111-4111-8111-111111111199")!,
      title: "Four hour review", startedAt: "2026-09-20T09:00:00+02:00",
      durationMs: durationMs, timeZone: "Europe/Bratislava",
      expectedLanguage: "en", expectedTerms: ["deployment"],
      participants: [
        EvidenceParticipant(
          speakerID: UUID(uuidString: "f000aa00-0000-4000-8000-000000000000")!,
          certainty: .confirmed, origin: "user_confirmation",
          knownSpeakerID: nil, name: "Oliver")
      ],
      candidateNames: [:], segments: segments, notes: [])
  }
}

// MARK: - Transport

/// A scripted `AnalysisTransporting`. Streams come from `responses/*.json`; one
/// stream index answers one request of that stage (the chunk index for `chunk`,
/// the consumption count otherwise), clamped to the last entry. `"*"` and
/// `"$seg:<n>"` placeholders resolve against the request and fixture.
final class FakeAnalysisTransport: AnalysisTransporting, @unchecked Sendable {
  /// Immutable scripted line objects; `@unchecked` because `[Any]` is not
  /// `Sendable` but the values are only read after creation.
  struct Lines: @unchecked Sendable { let value: [Any] }

  enum Step {
    /// Emit these line objects after `*`/`$seg` substitution.
    case lines(Lines)
    /// Throw through the stream.
    case failure(Error)
    /// Park inside `analyze` until the gate opens, then emit `lines`.
    case hold(PreparationGate, lines: Lines)
    /// Yield `firstByte`, then park until the gate opens, then emit `lines`.
    case holdAfterFirstByte(PreparationGate, lines: Lines)
    /// Emit lines, then wait for the gate before `completed`.
    case holdBeforeCompletion(PreparationGate, lines: Lines)
  }

  private let lock = NSLock()
  private var steps: [AnalysisStage: [Step]] = [:]
  private var consumed: [AnalysisStage: Int] = [:]
  private var fixture: IntelligenceFixture?
  private var queuedFailures: [Error] = []
  private(set) var requests: [AnalysisRequest] = []
  private(set) var requestByteSizes: [Int] = []
  private(set) var invalidateCount = 0
  private(set) var cancelledCount = 0
  var healthResult: Result<AnalysisHealth, Error>?

  init(fixture: IntelligenceFixture? = nil) { self.fixture = fixture }

  func script(_ stage: AnalysisStage, _ steps: [Step]) {
    lock.withLock { self.steps[stage] = steps }
  }

  /// Convenience: every stream of the fixture's scripted response file.
  func script(response name: String) throws {
    let streams = try IntelligenceFixtures.response(name)
    lock.withLock {
      for (stage, list) in streams {
        self.steps[stage] = list.map { .lines(Lines(value: $0)) }
      }
    }
  }

  func queueFailure(_ error: Error) {
    lock.withLock { queuedFailures.append(error) }
  }

  private func nextStep(for stage: AnalysisStage, index: Int) -> Step? {
    lock.withLock {
      if !queuedFailures.isEmpty { return .failure(queuedFailures.removeFirst()) }
      guard let list = steps[stage], !list.isEmpty else { return nil }
      let used = stage == .chunk ? index : (consumed[stage] ?? 0)
      consumed[stage] = used + 1
      let step = list[min(used, list.count - 1)]
      return step
    }
  }

  func analyze(
    request: AnalysisRequest, endpoint: RewriteEndpoint, timeout: Duration
  ) -> AsyncThrowingStream<AnalysisTransportItem, Error> {
    lock.withLock { requests.append(request) }
    let index = request.chunk?.index ?? 0
    let step = nextStep(for: request.stage, index: index)
    let fixture = self.fixture
    let body = (try? JSONSerialization.data(
      withJSONObject: requestJSONObject(request))) ?? Data()
    lock.withLock { requestByteSizes.append(body.count) }
    return AsyncThrowingStream { continuation in
      continuation.onTermination = { [weak self] state in
        guard case .cancelled = state, let self else { return }
        self.lock.withLock { self.cancelledCount += 1 }
      }
      Task {
        do {
          switch step {
          case .failure(let error):
            throw error
          case .hold(let gate, let lines):
            await gate.wait()
            try emit(
              lines: lines.value, request: request, fixture: fixture,
              continuation: continuation, bodyBytes: body.count)
          case .holdAfterFirstByte(let gate, let lines):
            continuation.yield(.firstByte)
            await gate.wait()
            try emit(
              lines: lines.value, request: request, fixture: fixture,
              continuation: continuation, bodyBytes: body.count, first: false)
          case .holdBeforeCompletion(let gate, let lines):
            try emit(
              lines: lines.value, request: request, fixture: fixture,
              continuation: continuation, bodyBytes: body.count, complete: false)
            await gate.wait()
            continuation.yield(
              .completed(requestBytes: body.count, responseBytes: 0))
          case .lines(let lines):
            try emit(
              lines: lines.value, request: request, fixture: fixture,
              continuation: continuation, bodyBytes: body.count)
          case nil:
            throw AnalysisFailure(.malformedResponse, detail: "no_script")
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }

  private func emit(
    lines: [Any], request: AnalysisRequest, fixture: IntelligenceFixture?,
    continuation: AsyncThrowingStream<AnalysisTransportItem, Error>.Continuation,
    bodyBytes: Int, first: Bool = true, complete: Bool = true
  ) throws {
    var responseBytes = 0
    if first { continuation.yield(.firstByte) }
    for raw in lines {
      let data: Data
      if let dict = raw as? [String: Any], let rawLine = dict["$raw"] as? String {
        data = Data(rawLine.utf8)
      } else {
        let resolved = substitute(raw, request: request, fixture: fixture)
        data = try JSONSerialization.data(withJSONObject: resolved)
      }
      if data.count > AnalysisBounds.maxLineBytes {
        throw AnalysisFailure(.oversizedResponse)
      }
      continuation.yield(.event(try AnalysisEvent.decode(line: data)))
      responseBytes += data.count
    }
    if complete {
      continuation.yield(.completed(requestBytes: bodyBytes, responseBytes: responseBytes))
    }
  }

  /// Depth-first `*`/`$seg:<n>` substitution per README.md.
  private func substitute(_ value: Any, request: AnalysisRequest, fixture: IntelligenceFixture?)
    -> Any
  {
    if let string = value as? String {
      if string.hasPrefix("$seg:"), let ordinal = Int(string.dropFirst(5)),
        let segment = fixture?.segments.first(where: { $0.ordinal == ordinal }) {
        return segment.id.uuidString
      }
      return string
    }
    guard let dict = value as? [String: Any] else { return value }
    var out = dict
    for (key, raw) in dict {
      if let string = raw as? String, string == "*" {
        switch key {
        case "request_id": out[key] = request.requestID.uuidString
        case "run_id": out[key] = request.runID.uuidString
        case "meeting_id": out[key] = request.meeting.id.uuidString
        case "language": out[key] = request.meeting.languagePolicy.output.rawValue
        default: out[key] = raw
        }
      } else {
        out[key] = substitute(raw, request: request, fixture: fixture)
      }
    }
    return out
  }

  private func requestJSONObject(_ request: AnalysisRequest) -> [String: Any] {
    guard let data = try? JSONEncoder().encode(request),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object
  }

  func health(endpoint: RewriteEndpoint) async throws -> AnalysisHealth {
    switch healthResult {
    case .success(let health): return health
    case .failure(let error): throw error
    case nil:
      return AnalysisHealth(
        schemaVersion: 1, service: AnalysisHealth.serviceName,
        protocolVersions: [1], serverName: "flowd", serverVersion: "0.3.0",
        backend: .init(state: "ready", kind: "openai-compatible", model: "test-model",
                       jsonSchema: true),
        promptVersions: ["full": 1, "chunk": 1, "synthesis": 1],
        resultSchemaVersion: 1,
        limits: .init(
          inputBytes: 98_304, outputBytes: 98_304, contextTokens: 32_768,
          concurrency: 1),
        caps: .init(
          sourcesPerItem: 10, topics: 20, decisions: 40, actionItems: 60,
          nextSteps: 40, openQuestions: 40, risks: 40))
    }
  }

  func invalidate() {
    lock.withLock { invalidateCount += 1 }
  }
}

// MARK: - Store

/// In-memory `AnalysisStoring`. Enforces the transition table and the per-meeting
/// capacities (`runRowsPerMeeting`, `overlaysPerMeeting`); `adopt` performs the
/// supersede-content-swap the SQL implementation must.
final class FakeAnalysisStore: AnalysisStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var pointers: [UUID: MeetingAnalysisPointer] = [:]
  private var runRows: [UUID: [AnalysisRun]] = [:]
  private var content: [UUID: StoredAnalysis] = [:]  // runID -> content
  private var overlayRows: [UUID: [UUID: AnalysisOverlay]] = [:]  // meetingID -> id -> row
  var runRowCap = 20
  var overlayCap = 500
  /// Injected failures by method name for persistence tests.
  var failures: [String: Error] = [:]
  private(set) var admitCalls = 0
  private(set) var adoptCalls = 0
  private(set) var startedRuns: [UUID] = []

  private func check(_ method: String) throws {
    if let error = failures[method] { throw error }
  }

  func analysis(meetingID: UUID) async throws -> MeetingAnalysisPointer? {
    try check("analysis")
    return lock.withLock { pointers[meetingID] }
  }

  func admit(
    meetingID: UUID, trigger: AnalysisTrigger, evidence: EvidenceVersion,
    passID: UUID, policy: AnalysisPolicy, now: Int64
  ) async throws -> AnalysisRun {
    try check("admit")
    return try lock.withLock {
      admitCalls += 1
      var runs = runRows[meetingID] ?? []
      if let current = runs.last(where: { !$0.state.isTerminal }) {
        throw AnalysisFailure(.malformedResponse, detail: "active_run_\(current.id)")
      }
      let run = AnalysisRun(
        id: UUID(), meetingID: meetingID, state: .pending, trigger: trigger,
        evidenceVersion: evidence.hex, transcriptPassID: passID,
        languagePolicy: nil,
        requestConfigJSON: policy.requestConfigJSON(), createdAt: now)
      runs.append(run)
      runRows[meetingID] = runs
      var pointer = pointers[meetingID]
        ?? MeetingAnalysisPointer(
          meetingID: meetingID, acceptedRunID: nil, currentRunID: nil,
          acceptedEvidenceVersion: nil, autoRestartedAt: nil)
      pointer.currentRunID = run.id
      pointers[meetingID] = pointer
      return run
    }
  }

  private func updateRun(_ id: UUID, _ mutate: (inout AnalysisRun) -> Void) {
    lock.withLock {
      for meetingID in runRows.keys {
        guard let runs = runRows[meetingID],
          let index = runs.firstIndex(where: { $0.id == id })
        else { continue }
        var run = runs[index]
        mutate(&run)
        var updated = runs
        updated[index] = run
        runRows[meetingID] = updated
        return
      }
    }
  }

  func start(runID: UUID, now: Int64) async throws -> AnalysisRun {
    try check("start")
    var result: AnalysisRun?
    updateRun(runID) {
      precondition($0.state.canTransition(to: .running))
      $0.state = .running
      $0.startedAt = now
      result = $0
    }
    lock.withLock { startedRuns.append(runID) }
    return result!
  }

  func recordRequest(
    runID: UUID, inputBytes: Int, outputBytes: Int, retried: Bool, preempted: Bool
  ) async throws {
    try check("recordRequest")
    updateRun(runID) {
      $0.requestCount += 1
      $0.inputBytes += inputBytes
      $0.outputBytes += outputBytes
      if retried { $0.retryCount += 1 }
      if preempted { $0.preemptionCount += 1 }
    }
  }

  func adopt(
    runID: UUID, result: ValidatedAnalysis, counts: ValidationCounts,
    identity: RunIdentity, now: Int64
  ) async throws -> AnalysisRun {
    try check("adopt")
    return try lock.withLock {
      adoptCalls += 1
      var adopted: AnalysisRun?
      for (meetingID, runs) in runRows {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { continue }
        var rows = runs
        for i in rows.indices where rows[i].state == .succeeded {
          rows[i].state = .superseded
        }
        var run = rows[index]
        precondition(run.state.canTransition(to: .succeeded))
        run.state = .succeeded
        run.completedAt = now
        run.serverVersion = identity.serverVersion
        run.protocolVersion = identity.protocolVersion
        run.schemaVersion = identity.schemaVersion
        run.backendKind = identity.backendKind
        run.backendModel = identity.backendModel
        run.promptVersions = identity.promptVersions
        run.pipelineVersion = identity.pipelineVersion
        run.itemCount = counts.itemCount
        run.droppedLiteralCount = counts.droppedLiteralCount
        run.droppedUnsupportedCount = counts.droppedUnsupportedCount
        run.identityDowngradeCount = counts.identityDowngradeCount
        run.unresolvedOwnerCount = counts.unresolvedOwnerCount
        rows[index] = run
        // Prune: keep at most `runRowCap` rows, always the run just adopted.
        while rows.count > runRowCap {
          if let drop = rows.firstIndex(where: {
            $0.id != runID && $0.state != .succeeded
          }) ?? rows.firstIndex(where: { $0.id != runID }) {
            content.removeValue(forKey: rows[drop].id)
            rows.remove(at: drop)
          } else { break }
        }
        runRows[meetingID] = rows
        guard var pointer = pointers[meetingID] else {
          throw AnalysisFailure(.persistenceFailure, detail: "pointer_missing")
        }
        pointer.acceptedRunID = runID
        pointer.currentRunID = nil
        pointer.acceptedEvidenceVersion = run.evidenceVersion
        pointers[meetingID] = pointer
        content[runID] = StoredAnalysis(
          run: run,
          summary: StoredSummary(
            text: result.summary.text, language: result.language,
            wholeMeeting: result.summary.wholeMeeting,
            sources: result.summary.sources),
          topics: result.topics.enumerated().map { ordinal, topic in
            StoredTopic(
              id: UUID(), ordinal: ordinal, title: topic.title,
              summary: topic.summary, bullets: topic.bullets,
              sources: topic.sources)
          },
          items: storedItems(result),
          overlays: overlayRows[meetingID]?.values.sorted {
            $0.createdAt < $1.createdAt
          } ?? [])
        adopted = run
        break
      }
      guard let adopted else {
        throw AnalysisFailure(.persistenceFailure, detail: "run_missing")
      }
      return adopted
    }
  }

  private func storedItems(_ result: ValidatedAnalysis) -> [StoredItem] {
    var items: [StoredItem] = []
    func append(_ kind: AnalysisItemKind, _ list: [(String, EvidenceClass?, [SourceRef])]) {
      for (ordinal, (text, evidence, sources)) in list.enumerated() {
        items.append(
          StoredItem(
            id: UUID(), kind: kind, ordinal: ordinal, text: text,
            evidenceClass: evidence, sources: sources))
      }
    }
    append(.decision, result.decisions.map { ($0.text, $0.evidenceClass, $0.sources) })
    for (ordinal, action) in result.actionItems.enumerated() {
      items.append(
        StoredItem(
          id: UUID(), kind: .actionItem, ordinal: ordinal, text: action.text,
          owner: action.owner, ownershipState: action.ownershipState,
          due: action.due, sources: action.sources))
    }
    append(.nextStep, result.nextSteps.map { ($0.text, $0.evidenceClass, $0.sources) })
    append(
      .openQuestion, result.openQuestions.map { ($0.text, $0.evidenceClass, $0.sources) })
    append(.risk, result.risks.map { ($0.text, $0.evidenceClass, $0.sources) })
    return items
  }

  private func transition(
    _ runID: UUID, to state: AnalysisRunState, now: Int64,
    failure: AnalysisFailureCategory? = nil, detail: String? = nil
  ) async {
    updateRun(runID) {
      precondition($0.state.canTransition(to: state), "\($0.state) -> \(state)")
      $0.state = state
      $0.completedAt = now
      $0.failureCategory = failure
      $0.failureDetail = detail
    }
    // Clear currentRunID if it pointed at this run.
    lock.withLock {
      for (meetingID, pointer) in pointers where pointer.currentRunID == runID {
        var updated = pointer
        updated.currentRunID = nil
        pointers[meetingID] = updated
      }
    }
  }

  func fail(runID: UUID, category: AnalysisFailureCategory, detail: String?, now: Int64)
    async throws
  {
    try check("fail")
    await transition(runID, to: .failed, now: now, failure: category, detail: detail)
  }

  func timeOut(runID: UUID, now: Int64) async throws {
    try check("timeOut")
    await transition(runID, to: .timedOut, now: now, failure: .timeout)
  }

  func cancel(runID: UUID, now: Int64) async throws {
    try check("cancel")
    await transition(runID, to: .cancelled, now: now)
  }

  func interrupt(runID: UUID, now: Int64) async throws {
    try check("interrupt")
    await transition(runID, to: .interrupted, now: now, failure: .interrupted)
  }

  func activeRuns(limit: Int) async throws -> [AnalysisRun] {
    try check("activeRuns")
    return lock.withLock {
      runRows.values.flatMap { $0 }.filter { !$0.state.isTerminal }
        .sorted { $0.createdAt < $1.createdAt }.prefix(limit).map { $0 }
    }
  }

  func latestRun(meetingID: UUID) async throws -> AnalysisRun? {
    lock.withLock { runRows[meetingID]?.sorted { $0.createdAt > $1.createdAt }.first }
  }

  func markAutoRestarted(meetingID: UUID, now: Int64) async throws {
    lock.withLock {
      var pointer = pointers[meetingID]
        ?? MeetingAnalysisPointer(
          meetingID: meetingID, acceptedRunID: nil, currentRunID: nil,
          acceptedEvidenceVersion: nil, autoRestartedAt: nil)
      pointer.autoRestartedAt = now
      pointers[meetingID] = pointer
    }
  }

  func readModel(meetingID: UUID) async throws -> StoredAnalysis? {
    try check("readModel")
    return lock.withLock {
      guard let accepted = pointers[meetingID]?.acceptedRunID else { return nil }
      return content[accepted]
    }
  }

  func setOverlay(
    meetingID: UUID, target: OverlayTarget, field: OverlayField,
    value: OverlayValue, snapshot: OverlaySnapshot, now: Int64
  ) async throws {
    try check("setOverlay")
    try lock.withLock {
      var rows = overlayRows[meetingID] ?? [:]
      let key = rows.first(where: { $0.value.targetKind == target && $0.value.field == field })
      if var row = key?.value {
        row.value = value
        row.snapshot = snapshot
        row.updatedAt = now
        row.orphanedAt = nil
        rows[row.id] = row
      } else {
        if rows.count >= overlayCap {
          throw AnalysisFailure(.persistenceCapacity, detail: "overlays_full")
        }
        let itemID: UUID? = { if case .item(let id) = target { return id }; return nil }()
        let row = AnalysisOverlay(
          id: UUID(), meetingID: meetingID, itemID: itemID, targetKind: target,
          itemKind: nil, field: field, value: value, snapshot: snapshot,
          createdAt: now, updatedAt: now, orphanedAt: nil)
        rows[row.id] = row
      }
      overlayRows[meetingID] = rows
    }
  }

  func removeOverlay(id: UUID) async throws {
    lock.withLock {
      for (meetingID, rows) in overlayRows {
        var updated = rows
        updated.removeValue(forKey: id)
        overlayRows[meetingID] = updated
      }
    }
  }

  func removeAllOverlays(meetingID: UUID) async throws {
    lock.withLock { overlayRows[meetingID] = [:] }
  }

  func overlays(meetingID: UUID) async throws -> [AnalysisOverlay] {
    lock.withLock {
      overlayRows[meetingID]?.values.sorted { $0.createdAt < $1.createdAt } ?? []
    }
  }

  func unfinishedRuns(limit: Int) async throws -> [AnalysisRun] {
    lock.withLock {
      runRows.values.flatMap { $0 }.filter { !$0.state.isTerminal }
        .sorted { $0.createdAt < $1.createdAt }.prefix(limit).map { $0 }
    }
  }

  func runs(meetingID: UUID, limit: Int) async throws -> [AnalysisRun] {
    lock.withLock {
      Array(
        (runRows[meetingID] ?? []).sorted { $0.createdAt > $1.createdAt }
          .prefix(limit))
    }
  }
}

// MARK: - Evidence reader

/// Paged in-memory `MeetingEvidenceReading`. Records the pages it served.
final class FakeEvidenceReader: MeetingEvidenceReading, @unchecked Sendable {
  private let lock = NSLock()
  var segments: [EvidenceSegment] = []
  var participantRows: [EvidenceParticipant] = []
  var noteRows: [NoteParagraph] = []
  var transcription: MeetingTranscription?
  var meetingRow: Meeting?
  private(set) var pageRequests: [(after: Int?, limit: Int)] = []

  init(fixture: IntelligenceFixture? = nil) {
    if let fixture {
      segments = fixture.segments
      participantRows = fixture.participants
      noteRows = fixture.notes
      meetingRow = fixture.meeting
      transcription = MeetingTranscription(
        meetingID: fixture.id, state: .final, liveRequested: false,
        liveState: nil, passID: UUID(), passKind: .final, engine: nil,
        modelID: nil, modelRevision: nil, modelManifestHash: nil,
        pipelineVersion: nil, plannerVersion: nil, vocabularyRevision: nil,
        vocabularyHash: nil, analysisDescriptor: nil, startedAt: nil,
        liveStartedAt: nil, finalizationStartedAt: nil, finalizedAt: 1,
        progressSequence: nil, progressSample: nil, updatedAt: 1)
    }
  }

  func segmentPage(meetingID: UUID, passID: UUID, after ordinal: Int?, limit: Int)
    async throws -> [EvidenceSegment]
  {
    lock.withLock {
      pageRequests.append((ordinal, limit))
      let start = ordinal.map { $0 + 1 } ?? 0
      return Array(segments.filter { $0.ordinal >= start }.prefix(limit))
    }
  }

  func participants(meetingID: UUID) async throws -> [EvidenceParticipant] {
    participantRows
  }

  func notes(meetingID: UUID) async throws -> [NoteParagraph] { noteRows }

  func transcription(meetingID: UUID) async throws -> MeetingTranscription? {
    transcription
  }

  func meeting(id: UUID) async throws -> Meeting? { meetingRow }
}
