import Foundation
import OSLog

/// The run executor (`contracts/client-analysis.md` "Run algorithm"). One `run`
/// call takes a meeting from eligibility to a terminal row state. Refusals that
/// happen before admission — a non-final transcript, a preflight refusal, a
/// missing endpoint, over-large notes — throw `AnalysisFailure` without a run
/// row; every later failure lands on the row (`failed`, `timed_out`,
/// `cancelled`) and the terminal row is returned. The staged path, preemption
/// retries and the run deadline arrive with the later stories.
struct MeetingAnalyzer: Sendable {
  private let evidence: any MeetingEvidenceReading
  private let transport: any AnalysisTransporting
  private let store: any AnalysisStoring
  private let clock: any MeetingClock
  private let endpoint: @MainActor @Sendable () -> RewriteEndpoint?
  private let settings: @MainActor @Sendable () -> RewriteSettings?
  private let recorder: ResourceRecorder?
  private let logger = Logger(subsystem: "org.localflow.LocalFlow", category: "analysis")

  /// Reports progress; the coordinator publishes it on the main actor.
  var progress: (@Sendable (UUID, AnalysisProgress?) -> Void)?

  init(
    evidence: any MeetingEvidenceReading, transport: any AnalysisTransporting,
    store: any AnalysisStoring, clock: any MeetingClock = SystemMeetingClock(),
    endpoint: @escaping @MainActor @Sendable () -> RewriteEndpoint?,
    settings: @escaping @MainActor @Sendable () -> RewriteSettings?,
    recorder: ResourceRecorder? = nil
  ) {
    self.evidence = evidence
    self.transport = transport
    self.store = store
    self.clock = clock
    self.endpoint = endpoint
    self.settings = settings
    self.recorder = recorder
  }

  // MARK: Run

  /// Everything `admit` captured: the pending row, the evidence snapshot the
  /// request is built from and the endpoint that passed preflight.
  struct Admission: Sendable {
    let run: AnalysisRun
    let passID: UUID
    let meeting: Meeting?
    let language: AnalysisLanguage
    let policy: AnalysisPolicy
    let endpoint: RewriteEndpoint
    let snapshot: Snapshot
  }

  /// Eligibility, preflight, evidence snapshot, language and version — shared
  /// by `admit` and `resumeAdmission`. Throws without a row on refusal.
  private struct Prepared: Sendable {
    var passID: UUID
    var meeting: Meeting?
    var snapshot: Snapshot
    var language: AnalysisLanguage
    var policy: AnalysisPolicy
    var endpoint: RewriteEndpoint
    var version: EvidenceVersion
  }

  private func prepare(meetingID: UUID) async throws -> Prepared {
    // 1. Eligibility: final transcript with a pass id, else refuse with no row.
    guard let transcription = try await evidence.transcription(meetingID: meetingID),
      transcription.state == .final, let passID = transcription.passID
    else { throw AnalysisFailure(.notEligible) }

    // 2. Preflight the endpoint like rewrite; a refusal needs no request.
    if let settings = await settings(),
      let refusal = RewriteConnectionCategory.preflight(settings)
    {
      throw AnalysisFailure(Self.mapPreflight(refusal))
    }
    guard let endpoint = await endpoint() else {
      throw AnalysisFailure(.serverUnavailable, detail: AnalysisClient.unavailableMessage)
    }

    // 3. Evidence snapshot, language policy and version (R8, R10).
    let snapshot = try await loadEvidence(meetingID: meetingID, passID: passID)
    let policy = AnalysisPolicy()
    guard snapshot.notes.count <= policy.maxNoteParagraphs,
      snapshot.notes.allSatisfy({ $0.text.utf8.count <= policy.maxNoteParagraphBytes })
    else { throw AnalysisFailure(.tooLong, detail: "notes_too_large") }
    let meeting = try await evidence.meeting(id: meetingID)
    let language = LanguagePolicy.detect(
      segments: snapshot.segments, sampleBytes: policy.languageSampleBytes)
    let version = Self.compute(
      meetingID: meetingID, passID: passID, snapshot: snapshot,
      language: language, policy: policy)
    return Prepared(
      passID: passID, meeting: meeting, snapshot: snapshot, language: language,
      policy: policy, endpoint: endpoint, version: version)
  }

  /// Eligibility, preflight, evidence snapshot and the `pending` row.
  /// Refusals here throw without a row (contract "Run algorithm").
  func admit(meetingID: UUID, trigger: AnalysisTrigger) async throws -> Admission {
    let prepared = try await prepare(meetingID: meetingID)
    let run = try await store.admit(
      meetingID: meetingID, trigger: trigger, evidence: prepared.version,
      passID: prepared.passID, policy: prepared.policy, now: clock.nowMilliseconds)
    return Admission(
      run: run, passID: prepared.passID, meeting: prepared.meeting,
      language: prepared.language, policy: prepared.policy,
      endpoint: prepared.endpoint, snapshot: prepared.snapshot)
  }

  /// Launch resume: the meeting already holds a `pending` row. The snapshot is
  /// rebuilt; if evidence drifted while the app was away the pre-adoption
  /// check fails the run with `evidence_changed`, as it should.
  func resumeAdmission(meetingID: UUID) async throws -> Admission {
    guard let run = try await store.latestRun(meetingID: meetingID),
      run.state == .pending
    else { throw AnalysisFailure(.notEligible, detail: "no_pending_run") }
    let prepared = try await prepare(meetingID: meetingID)
    return Admission(
      run: run, passID: prepared.passID, meeting: prepared.meeting,
      language: prepared.language, policy: prepared.policy,
      endpoint: prepared.endpoint, snapshot: prepared.snapshot)
  }

  /// One-shot convenience: admit then execute.
  func run(meetingID: UUID, trigger: AnalysisTrigger) async throws -> AnalysisRun {
    try await execute(admit(meetingID: meetingID, trigger: trigger))
  }

  /// The evidence version as it stands now; nil without a final transcript.
  /// The Summary tab marks its accepted run stale when this differs from the
  /// run's `evidence_version`; `evidenceDidChange` reuses it (T076).
  func currentEvidenceVersion(meetingID: UUID) async throws -> String? {
    guard let transcription = try await evidence.transcription(meetingID: meetingID),
      transcription.state == .final, let passID = transcription.passID
    else { return nil }
    let snapshot = try await loadEvidence(meetingID: meetingID, passID: passID)
    let policy = AnalysisPolicy()
    let language = LanguagePolicy.detect(
      segments: snapshot.segments, sampleBytes: policy.languageSampleBytes)
    return Self.compute(
      meetingID: meetingID, passID: passID, snapshot: snapshot,
      language: language, policy: policy
    ).hex
  }

  /// `pending` → a terminal row state. Every failure lands on the row.
  func execute(_ admission: Admission) async throws -> AnalysisRun {
    let meetingID = admission.run.meetingID
    var run = admission.run
    do {
      run = try await store.start(runID: run.id, now: clock.nowMilliseconds)
      progress?(meetingID, AnalysisProgress(label: "Analyzing", fraction: 0))

      // 5. Health: `result_schema_version` and the limits/caps minima.
      let health = try await transport.health(endpoint: admission.endpoint)
      if let schema = health.resultSchemaVersion, schema != 1 {
        throw AnalysisFailure(.unsupportedVersion, detail: "result_schema_version")
      }
      let effective = admission.policy.lowered(by: health)

      // 6. One `full` request, consumed to a validated result.
      let request = Self.request(
        meetingID: meetingID, runID: run.id, meeting: admission.meeting,
        snapshot: admission.snapshot, language: admission.language)
      let result = try await consume(
        request: request, endpoint: admission.endpoint, runID: run.id,
        meetingID: meetingID, policy: effective)

      // 7. Validate against the same evidence. The due step re-resolves
      // relative phrases against the meeting's start in its zone.
      var analysisEvidence = admission.snapshot.evidence(meetingID: meetingID)
      analysisEvidence.meetingStartedAtMs =
        admission.meeting?.startedAt ?? admission.meeting?.createdAt
      analysisEvidence.meetingTimeZone = admission.meeting?.timeZone
      let (validated, counts) = try AnalysisValidator.validate(
        result: result.analysis,
        against: analysisEvidence,
        policy: effective)

      // 8. The evidence must not have drifted mid-run.
      let fresh = try await loadEvidence(meetingID: meetingID, passID: admission.passID)
      guard
        Self.compute(
          meetingID: meetingID, passID: admission.passID, snapshot: fresh,
          language: admission.language, policy: admission.policy
        )
        .hex == admission.run.evidenceVersion
      else {
        throw AnalysisFailure(.sourceValidation, detail: "evidence_changed")
      }

      // 9. Adopt: supersede, content swap, re-point, re-match overlays.
      let identity = Self.identity(health: health, payload: result.payload)
      run = try await store.adopt(
        runID: run.id, result: validated, counts: counts, identity: identity,
        now: clock.nowMilliseconds)
      progress?(meetingID, nil)
      return run
    } catch is CancellationError {
      try? await store.cancel(runID: run.id, now: clock.nowMilliseconds)
      progress?(meetingID, nil)
      throw CancellationError()
    } catch let failure as AnalysisFailure {
      try? await finish(runID: run.id, meetingID: meetingID, failure: failure)
      progress?(meetingID, nil)
      return (try? await store.latestRun(meetingID: meetingID)) ?? run
    } catch {
      try? await store.fail(
        runID: run.id, category: .persistenceFailure, detail: "internal_error",
        now: clock.nowMilliseconds)
      progress?(meetingID, nil)
      return (try? await store.latestRun(meetingID: meetingID)) ?? run
    }
  }

  private func finish(runID: UUID, meetingID: UUID, failure: AnalysisFailure) async throws {
    let now = clock.nowMilliseconds
    if failure.category == .timeout {
      try await store.timeOut(runID: runID, now: now)
    } else {
      try await store.fail(
        runID: runID, category: failure.category, detail: failure.detail, now: now)
    }
  }

  // MARK: Evidence

  struct Snapshot {
    var segments: [EvidenceSegment]
    var participants: [EvidenceParticipant]
    /// Local-only: the validator's mentioned-owner downgrade compares against
    /// these; they never enter the request.
    var possibleCandidateNames: Set<String> = []
    var notes: [NoteParagraph]

    func evidence(meetingID: UUID) -> AnalysisEvidence {
      AnalysisEvidence(
        meetingID: meetingID,
        segmentIDs: Set(segments.map(\.id)),
        segmentText: Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.text) }),
        notes: notes, participants: participants,
        possibleCandidateNames: possibleCandidateNames)
    }
  }

  /// Paged final segments (≤ `evidencePageSize` rows at a time), participants
  /// and notes. Nothing here triggers transcription, diarization or
  /// identification work — the reader has no write methods (FR-009).
  private func loadEvidence(meetingID: UUID, passID: UUID) async throws -> Snapshot {
    var segments: [EvidenceSegment] = []
    var after: Int? = nil
    while true {
      let page = try await evidence.segmentPage(
        meetingID: meetingID, passID: passID, after: after,
        limit: AnalysisPolicy().evidencePageSize)
      guard !page.isEmpty else { break }
      segments.append(contentsOf: page)
      guard page.count >= AnalysisPolicy().evidencePageSize,
        let last = page.last?.ordinal
      else { break }
      after = last
    }
    return try await Snapshot(
      segments: segments, participants: evidence.participants(meetingID: meetingID),
      possibleCandidateNames: evidence.possibleCandidateNames(meetingID: meetingID),
      notes: evidence.notes(meetingID: meetingID))
  }

  private static func compute(
    meetingID: UUID, passID: UUID, snapshot: Snapshot,
    language: AnalysisLanguage, policy: AnalysisPolicy
  ) -> EvidenceVersion {
    EvidenceVersion.compute(
      meetingID: meetingID, passID: passID, segments: snapshot.segments,
      participants: snapshot.participants, notes: snapshot.notes,
      languageOutput: language, preserveTerms: true,
      chunkBudgetBytes: policy.chunkBudgetBytes)
  }

  // MARK: Request

  private static func request(
    meetingID: UUID, runID: UUID, meeting: Meeting?, snapshot: Snapshot,
    language: AnalysisLanguage
  ) -> AnalysisRequest {
    let title = meeting?.displayTitle ?? "Meeting"
    let startedMs = meeting?.startedAt ?? meeting?.createdAt ?? 0
    let durationMs = meeting?.wallClockMs ?? 0
    return AnalysisRequest(
      requestID: UUID(), runID: runID, stage: .full, chunk: nil,
      meeting: AnalysisRequest.Meeting(
        id: meetingID,
        title: String(decoding: title.utf8.prefix(AnalysisBounds.maxTitleBytes), as: UTF8.self),
        startedAt: rfc3339(ms: startedMs), durationMs: durationMs,
        timeZone: String(
          decoding: (meeting?.timeZone ?? TimeZone.current.identifier).utf8
            .prefix(AnalysisBounds.maxTimeZoneBytes),
          as: UTF8.self),
        languagePolicy: LanguagePolicy.requestValue(output: language)),
      participants: snapshot.participants.map { participant in
        AnalysisRequest.Participant(
          speakerID: participant.speakerID, certainty: participant.certainty,
          origin: String(
            decoding: participant.origin.utf8.prefix(AnalysisBounds.maxOriginBytes), as: UTF8.self),
          knownSpeakerID: participant.knownSpeakerID,
          name: participant.certainty.mayBeNamed
            ? participant.name.map {
              String(
                decoding: $0.utf8.prefix(AnalysisBounds.maxParticipantNameBytes), as: UTF8.self)
            }
            : nil)
      },
      segments: snapshot.segments.map { segment in
        AnalysisRequest.Segment(
          id: segment.id, startMs: segment.startMs, endMs: segment.endMs,
          speakerID: {
            if case .speaker(let id) = segment.speaker { return id }
            return nil
          }(),
          text: segment.text)
      },
      notes: snapshot.notes.map { AnalysisRequest.Note(ordinal: $0.ordinal, text: $0.text) },
      partials: nil)
  }

  private static func rfc3339(ms: Int64) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
    formatter.timeZone = TimeZone.current
    return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1_000))
  }

  // MARK: Stream

  private struct Outcome: Sendable {
    var analysis: AnalysisResult
    var payload: AnalysisEvent.ResultPayload
  }

  private func consume(
    request: AnalysisRequest, endpoint: RewriteEndpoint, runID: UUID, meetingID: UUID,
    policy: AnalysisPolicy
  ) async throws -> Outcome {
    var result: Outcome?
    var requestBytes = 0
    var responseBytes = 0
    let stream = transport.analyze(
      request: request, endpoint: endpoint, timeout: policy.perRequestTimeout)
    for try await item in stream {
      try Task.checkCancellation()
      switch item {
      case .firstByte:
        progress?(meetingID, AnalysisProgress(label: "Analyzing", fraction: 0.05))
      case .event(let event):
        switch event {
        case .accepted:
          progress?(meetingID, AnalysisProgress(label: "Analyzing", fraction: 0.1))
        case .progress(_, _, let chars):
          let total = max(1, request.segments?.reduce(0) { $0 + $1.text.count } ?? 1)
          progress?(
            meetingID,
            AnalysisProgress(
              label: "Analyzing", fraction: min(0.9, 0.1 + 0.8 * Double(chars) / Double(total))))
        case .result(let payload):
          result = Outcome(analysis: payload.analysis, payload: payload)
        case .error(_, let code):
          throw AnalysisFailure(AnalysisFailureCategory.forServerCode(code))
        }
      case .completed(let requestBytes_, let responseBytes_):
        requestBytes = requestBytes_
        responseBytes = responseBytes_
      }
    }
    try await store.recordRequest(
      runID: runID, inputBytes: requestBytes, outputBytes: responseBytes,
      retried: false, preempted: false)
    guard let result else { throw AnalysisFailure(.malformedResponse, detail: "no_result") }
    return result
  }

  // MARK: Mapping

  private static func mapPreflight(_ refusal: RewriteConnectionCategory)
    -> AnalysisFailureCategory
  {
    switch refusal {
    case .authenticationFailed, .missingCredential: return .authenticationFailed
    default: return .serverUnavailable
    }
  }

  private static func identity(health: AnalysisHealth, payload: AnalysisEvent.ResultPayload)
    -> RunIdentity
  {
    let promptVersions =
      health.promptVersions.sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    return RunIdentity(
      serverVersion: payload.server?.version ?? health.serverVersion ?? "",
      protocolVersion: 1, schemaVersion: payload.analysis.schemaVersion,
      backendKind: payload.backend?.kind ?? health.backend?.kind ?? "",
      backendModel: payload.backend?.model ?? health.backend?.model ?? "",
      promptVersions: promptVersions,
      pipelineVersion: payload.pipelineVersion ?? AnalysisPolicy.pipelineVersion)
  }
}
