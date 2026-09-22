import Foundation
import GRDB
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
    let language = LanguagePolicy.resolve(
      segments: snapshot.segments, sampleBytes: policy.languageSampleBytes,
      meetingLanguage: meeting?.language, transcriptPipeline: transcription.pipelineVersion)
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
    // One automatic run per finalized pass: a late settle event after a manual
    // or earlier automatic acceptance must not regenerate on its own (FR-031).
    if trigger == .automatic,
      let pointer = try? await store.analysis(meetingID: meetingID),
      let acceptedID = pointer.acceptedRunID,
      let accepted = try? await store.runs(meetingID: meetingID, limit: AnalysisStore.runRowCap)
        .first(where: { $0.id == acceptedID }),
      accepted.transcriptPassID == prepared.passID
    {
      throw AnalysisFailure(.notEligible, detail: "automatic_already_accepted")
    }
    let run = try await store.admit(
      meetingID: meetingID, trigger: trigger, evidence: prepared.version,
      passID: prepared.passID, policy: prepared.policy, now: clock.nowMilliseconds)
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
    let meeting = try await evidence.meeting(id: meetingID)
    let language = LanguagePolicy.resolve(
      segments: snapshot.segments, sampleBytes: policy.languageSampleBytes,
      meetingLanguage: meeting?.language, transcriptPipeline: transcription.pipelineVersion)
    return Self.compute(
      meetingID: meetingID, passID: passID, snapshot: snapshot,
      language: language, policy: policy
    ).hex
  }

  /// `pending` → a terminal row state. Every failure lands on the row.
  func execute(_ admission: Admission) async throws -> AnalysisRun {
    let meetingID = admission.run.meetingID
    var run = admission.run
    // T102: the run's numbers, never its text, ids or names. Emitted
    // on every exit — a started run reports its counters, a refused one
    // reports nothing.
    defer { recordTerminal(run) }
    do {
      run = try await store.start(runID: run.id, now: clock.nowMilliseconds)
      progress?(meetingID, AnalysisProgress(label: "Analyzing", fraction: 0))
      let runID = run.id

      // 5. Health: `result_schema_version` and the limits/caps minima. The
      // plan needs the lowered budget, so health runs ahead of the deadline
      // window; `chunk_count` lands on the row before the first request.
      let health = try await self.transport.health(endpoint: admission.endpoint)
      if let schema = health.resultSchemaVersion, schema != 1 {
        throw AnalysisFailure(.unsupportedVersion, detail: "result_schema_version")
      }
      let effective = admission.policy.lowered(by: health)
      let plan = try AnalysisChunkPlanner.plan(
        segments: admission.snapshot.segments, notes: admission.snapshot.notes,
        policy: effective)
      try await store.recordPlan(runID: runID, chunkCount: plan.chunks.count)

      // R11: requests, validation and adoption race the deadline, sized to
      // the plan's request count (60 s + 90 s each, clamped).
      let deadline = admission.policy.runDeadline(requestCount: plan.requestCount)
      run = try await racing(deadline) {
        // 6. One `full` request, or `chunk × n` then bounded synthesis.
        let result = try await self.perform(
          plan, admission: admission, effective: effective,
          runID: runID, meetingID: meetingID)

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
        guard
          try await self.currentEvidenceVersion(meetingID: meetingID)
            == admission.run.evidenceVersion
        else {
          throw AnalysisFailure(.sourceValidation, detail: "evidence_changed")
        }

        // 9. Adopt: supersede, content swap, re-point, re-match overlays.
        let identity = Self.identity(health: health, payload: result.payload)
        let adopted = try await self.store.adopt(
          runID: runID, result: validated, counts: counts, identity: identity,
          now: self.clock.nowMilliseconds)
        let orphans =
          (try? await self.store.overlays(meetingID: meetingID))?
          .filter { $0.orphanedAt != nil }.count ?? 0
        self.recorder?.record(
          phase: .analysisAdopting, metric: .analysisOverlayOrphanCount,
          itemCount: UInt32(clamping: orphans))
        return adopted
      }
      progress?(meetingID, nil)
      return run
    } catch is CancellationError {
      try? await store.cancel(runID: run.id, now: clock.nowMilliseconds)
      run = await terminalRun(run, limit: admission.policy.runRowsPerMeeting)
      progress?(meetingID, nil)
      throw CancellationError()
    } catch let failure as AnalysisFailure {
      try? await finish(runID: run.id, meetingID: meetingID, failure: failure)
      progress?(meetingID, nil)
      run = await terminalRun(run, limit: admission.policy.runRowsPerMeeting)
      return (try? await store.latestRun(meetingID: meetingID)) ?? run
    } catch AnalysisStore.Error.lateWrite {
      // FR-011: a newer run won the `current_run_id` race; this result is
      // discarded and the run is superseded, never failed.
      try? await store.supersede(runID: run.id, now: clock.nowMilliseconds)
      progress?(meetingID, nil)
      run = await terminalRun(run, limit: admission.policy.runRowsPerMeeting)
      return (try? await store.latestRun(meetingID: meetingID)) ?? run
    } catch {
      // The history-database ceiling is a capacity refusal, not a fault.
      let category: AnalysisFailureCategory =
        (error as? DatabaseError)?.resultCode == .SQLITE_FULL
        ? .persistenceCapacity : .persistenceFailure
      try? await store.fail(
        runID: run.id, category: category, detail: "internal_error",
        now: clock.nowMilliseconds)
      progress?(meetingID, nil)
      run = await terminalRun(run, limit: admission.policy.runRowsPerMeeting)
      return (try? await store.latestRun(meetingID: meetingID)) ?? run
    }
  }

  /// Runs `operation` against a `clock` sleeper; whichever finishes first
  /// decides. Expiry throws `AnalysisFailure(.timeout)` and cancels the work
  /// task — the stream stops at the next cancellation point, and `finish`
  /// writes `timed_out`. A cancelled run task surfaces as `CancellationError`.
  private func racing(
    _ deadline: Duration,
    operation: @escaping @Sendable () async throws -> AnalysisRun
  ) async throws -> AnalysisRun {
    enum Outcome: Sendable {
      case done(AnalysisRun)
      case expired
    }
    return try await withThrowingTaskGroup(of: Outcome.self) { group in
      group.addTask { .done(try await operation()) }
      group.addTask {
        try await self.clock.sleep(for: deadline)
        return .expired
      }
      for try await outcome in group {
        group.cancelAll()
        switch outcome {
        case .done(let run): return run
        case .expired: throw AnalysisFailure(.timeout)
        }
      }
      throw CancellationError()
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

  /// Read this run rather than the latest run: a newer admission may already
  /// exist when a cancelled or superseded execution finishes.
  private func terminalRun(_ run: AnalysisRun, limit: Int) async -> AnalysisRun {
    (try? await store.runs(meetingID: run.meetingID, limit: limit))?
      .first { $0.id == run.id } ?? run
  }

  /// T102: terminal counters, durations and byte sizes, without content.
  private func recordTerminal(_ run: AnalysisRun) {
    guard let recorder, run.startedAt != nil else { return }
    if run.durationMs > 0 {
      recorder.record(
        phase: .analysisAdopting,
        durationNanoseconds: UInt64(run.durationMs) * 1_000_000,
        metric: .analysisRunDuration)
    }
    recorder.record(
      phase: .analysisRequesting, metric: .analysisInputBytes,
      payloadBytes: UInt64(clamping: run.inputBytes))
    recorder.record(
      phase: .analysisRequesting, metric: .analysisOutputBytes,
      payloadBytes: UInt64(clamping: run.outputBytes))
    let requesting: [(ResourceRecorder.Metric, Int)] = [
      (.analysisRequestCount, run.requestCount),
      (.analysisRetryCount, run.retryCount),
      (.analysisPreemptionCount, run.preemptionCount),
      (.analysisChunkCount, run.chunkCount),
    ]
    for (metric, value) in requesting {
      recorder.record(
        phase: .analysisRequesting, metric: metric,
        itemCount: UInt32(clamping: max(0, value)))
    }
    let validating: [(ResourceRecorder.Metric, Int)] = [
      (.analysisDroppedLiteralCount, run.droppedLiteralCount),
      (.analysisDroppedUnsupportedCount, run.droppedUnsupportedCount),
      (.analysisIdentityDowngradeCount, run.identityDowngradeCount),
      (.analysisUnresolvedOwnerCount, run.unresolvedOwnerCount),
    ]
    for (metric, value) in validating {
      recorder.record(
        phase: .analysisValidating, metric: metric,
        itemCount: UInt32(clamping: max(0, value)))
    }
    recorder.record(
      phase: .analysisAdopting, metric: .analysisItemCount,
      itemCount: UInt32(clamping: max(0, run.itemCount)))
    if let category = run.failureCategory {
      recorder.record(
        phase: .analysisAdopting, metric: .analysisFailure, itemCount: 1,
        meetingKey: category.rawValue)
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

  // MARK: Stages

  /// `full` or `chunk × n` → bounded synthesis (contract step 6). Requests
  /// run sequentially — `policy.requestsInFlight` is 1 — so the transport
  /// never sees two in flight. Every result is validated; partials are kept
  /// as bounded Swift values and forwarded into `partials` unchanged.
  private func perform(
    _ plan: AnalysisChunkPlanner.Plan, admission: Admission,
    effective: AnalysisPolicy, runID: UUID, meetingID: UUID
  ) async throws -> Outcome {
    if plan.isFull {
      let request = Self.request(
        meetingID: meetingID, runID: runID, meeting: admission.meeting,
        snapshot: admission.snapshot, language: admission.language,
        stage: .full, chunk: nil, segments: admission.snapshot.segments,
        notes: admission.snapshot.notes, partials: nil)
      return try await consumeWithPreemptionRetry(
        request: request, endpoint: admission.endpoint, runID: runID,
        meetingID: meetingID, policy: effective, label: "Analyzing")
    }

    var analysisEvidence = admission.snapshot.evidence(meetingID: meetingID)
    analysisEvidence.meetingStartedAtMs =
      admission.meeting?.startedAt ?? admission.meeting?.createdAt
    analysisEvidence.meetingTimeZone = admission.meeting?.timeZone

    // Chunks: each request is built from one paged window — never more than
    // one chunk plus a page of text in memory. The tail is never dropped:
    // the plan's windows cover every segment.
    var partials: [AnalysisResult] = []
    for chunk in plan.chunks {
      let label = "Analyzing part \(chunk.index + 1) of \(plan.chunks.count)"
      let segments = try await segmentWindow(
        meetingID: meetingID, passID: admission.passID,
        first: chunk.firstOrdinal, last: chunk.lastOrdinal,
        pageSize: effective.evidencePageSize)
      let request = Self.request(
        meetingID: meetingID, runID: runID, meeting: admission.meeting,
        snapshot: admission.snapshot, language: admission.language,
        stage: .chunk,
        chunk: .init(index: chunk.index, count: plan.chunks.count),
        segments: segments, notes: nil, partials: nil)
      let outcome = try await consumeWithPreemptionRetry(
        request: request, endpoint: admission.endpoint, runID: runID,
        meetingID: meetingID, policy: effective, label: label)
      try Self.checkPartial(outcome.analysis, against: analysisEvidence, policy: effective)
      partials.append(outcome.analysis)
    }

    // Reduce: groups of ≤ `partialsPerSynthesis`, ≤ `reduceDepth` levels.
    // Notes ride the final synthesis request only.
    var inputs = partials
    var final: Outcome?
    for (level, count) in plan.synthesisCounts.enumerated() {
      let lastLevel = level == plan.synthesisCounts.count - 1
      var outputs: [AnalysisResult] = []
      for start in stride(from: 0, to: inputs.count, by: effective.partialsPerSynthesis) {
        let group = Array(inputs[start..<min(start + effective.partialsPerSynthesis, inputs.count)])
        let isFinal = lastLevel && outputs.count == count - 1
        let request = Self.request(
          meetingID: meetingID, runID: runID, meeting: admission.meeting,
          snapshot: admission.snapshot, language: admission.language,
          stage: .synthesis, chunk: nil, segments: nil,
          notes: isFinal ? admission.snapshot.notes : nil, partials: group)
        let outcome = try await consumeWithPreemptionRetry(
          request: request, endpoint: admission.endpoint, runID: runID,
          meetingID: meetingID, policy: effective, label: "Combining")
        if isFinal {
          final = outcome
        } else {
          try Self.checkPartial(outcome.analysis, against: analysisEvidence, policy: effective)
        }
        outputs.append(outcome.analysis)
      }
      inputs = outputs
    }
    guard let final else { throw AnalysisFailure(.malformedResponse, detail: "no_result") }
    return final
  }

  /// One chunk's segment window, paged from the reader so the builder holds
  /// at most a chunk plus a page. `first..<last` are pass ordinals.
  private func segmentWindow(
    meetingID: UUID, passID: UUID, first: Int, last: Int, pageSize: Int
  ) async throws -> [EvidenceSegment] {
    var segments: [EvidenceSegment] = []
    var after: Int? = first > 0 ? first - 1 : nil
    while true {
      let page = try await evidence.segmentPage(
        meetingID: meetingID, passID: passID, after: after, limit: pageSize)
      guard let lastSeen = page.last?.ordinal else { break }
      segments.append(
        contentsOf: page.filter { $0.ordinal >= first && $0.ordinal < last })
      guard lastSeen < last - 1 else { break }
      after = lastSeen
    }
    return segments
  }

  // MARK: Request

  private static func request(
    meetingID: UUID, runID: UUID, meeting: Meeting?, snapshot: Snapshot,
    language: AnalysisLanguage, stage: AnalysisStage, chunk: AnalysisRequest.Chunk?,
    segments: [EvidenceSegment]?, notes: [NoteParagraph]?, partials: [AnalysisResult]?
  ) -> AnalysisRequest {
    let title = meeting?.displayTitle ?? "Meeting"
    let startedMs = meeting?.startedAt ?? meeting?.createdAt ?? 0
    let durationMs = meeting?.wallClockMs ?? 0
    return AnalysisRequest(
      requestID: UUID(), runID: runID, stage: stage, chunk: chunk,
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
          knownSpeakerID: participant.certainty.mayCarryKnownSpeaker
            ? participant.knownSpeakerID : nil,
          name: participant.certainty.mayBeNamed
            ? participant.name.map {
              String(
                decoding: $0.utf8.prefix(AnalysisBounds.maxParticipantNameBytes), as: UTF8.self)
            }
            : nil)
      },
      segments: segments?.map { segment in
        AnalysisRequest.Segment(
          id: segment.id, startMs: segment.startMs, endMs: segment.endMs,
          speakerID: {
            if case .speaker(let id) = segment.speaker { return id }
            return nil
          }(),
          text: segment.text)
      },
      notes: notes?.map { AnalysisRequest.Note(ordinal: $0.ordinal, text: $0.text) },
      partials: partials)
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

  /// An intermediate result is forwarded to synthesis unchanged and never
  /// adopted, so only the run-failing source rules (FR-024) apply to it. The
  /// literal and dropped-share rules (FR-024a) judge the adopted result: a
  /// small model's partial often carries one invented name, and failing the
  /// whole run on it protects nothing the final validation does not.
  private static func checkPartial(
    _ result: AnalysisResult, against evidence: AnalysisEvidence, policy: AnalysisPolicy
  ) throws {
    do {
      _ = try AnalysisValidator.validate(result: result, against: evidence, policy: policy)
    } catch let failure as AnalysisFailure
      where failure.category == .protectedLiteral || failure.category == .unsupportedContent
    {}
  }

  /// `consume` plus the preemption rule (contract step 6): on a `preempted`
  /// error the same stage is retried after 2 s × attempt, at most
  /// `preemptionRetries` times, then the run fails `backend_busy`. The
  /// preempted attempt is recorded on the row — it consumed server time.
  private func consumeWithPreemptionRetry(
    request: AnalysisRequest, endpoint: RewriteEndpoint, runID: UUID,
    meetingID: UUID, policy: AnalysisPolicy, label: String
  ) async throws -> Outcome {
    var attempt = 0
    while true {
      do {
        return try await consume(
          request: request, endpoint: endpoint, runID: runID,
          meetingID: meetingID, policy: policy, label: label,
          retried: attempt > 0)
      } catch let failure as AnalysisFailure
        where failure.category == .backendBusy && failure.detail == "preempted"
      {
        try? await store.recordRequest(
          runID: runID, inputBytes: 0, outputBytes: 0,
          retried: attempt > 0, preempted: true)
        attempt += 1
        guard attempt <= policy.preemptionRetries else { throw failure }
        try await clock.sleep(for: .seconds(2 * attempt))
      }
    }
  }

  private func consume(
    request: AnalysisRequest, endpoint: RewriteEndpoint, runID: UUID, meetingID: UUID,
    policy: AnalysisPolicy, label: String, retried: Bool = false
  ) async throws -> Outcome {
    var result: Outcome?
    var requestBytes = 0
    var responseBytes = 0
    let began = clock.monotonicNanoseconds
    defer {
      recorder?.record(
        phase: .analysisRequesting,
        durationNanoseconds: clock.monotonicNanoseconds &- began,
        metric: .analysisStageDuration)
    }
    let stream = transport.analyze(
      request: request, endpoint: endpoint, timeout: policy.perRequestTimeout)
    for try await item in stream {
      try Task.checkCancellation()
      switch item {
      case .firstByte:
        progress?(meetingID, AnalysisProgress(label: label, fraction: 0.05))
      case .event(let event):
        switch event {
        case .accepted:
          progress?(meetingID, AnalysisProgress(label: label, fraction: 0.1))
        case .progress(_, _, let chars):
          let total = max(1, request.segments?.reduce(0) { $0 + $1.text.count } ?? 1)
          progress?(
            meetingID,
            AnalysisProgress(
              label: label, fraction: min(0.9, 0.1 + 0.8 * Double(chars) / Double(total))))
        case .result(let payload):
          // A result that names another run is stale protocol noise — the
          // store's `running` + `current_run_id` guard is the second line.
          guard payload.runID == nil || payload.runID == runID.uuidString else {
            throw AnalysisFailure(.malformedResponse, detail: "run_id")
          }
          result = Outcome(analysis: payload.analysis, payload: payload)
        case .error(_, let code):
          throw AnalysisFailure(
            AnalysisFailureCategory.forServerCode(code), detail: code)
        }
      case .completed(let requestBytes_, let responseBytes_):
        requestBytes = requestBytes_
        responseBytes = responseBytes_
      }
    }
    // A cancelled stream can end `nil` without throwing; the run still writes
    // `cancelled`, not a malformed-response failure.
    try Task.checkCancellation()
    try await store.recordRequest(
      runID: runID, inputBytes: requestBytes, outputBytes: responseBytes,
      retried: retried, preempted: false)
    guard let result else { throw AnalysisFailure(.malformedResponse, detail: "no_result") }
    guard result.analysis.language == request.meeting.languagePolicy.output else {
      throw AnalysisFailure(.malformedResponse, detail: "language_policy")
    }
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
