import Foundation
import GRDB
import LocalFlowCore

/// The summary of a merged phone meeting (research R4). The handoff brings back the
/// transcript and speaker labels; the summary goes through the server's `analysis` op like
/// the Mac's: final segments with their speaker roots and the notes become an
/// `AnalysisRequest` (one `full` request, or chunks then synthesis), the result is checked
/// with `AnalysisValidator` and stored with `AnalysisStore.adopt`. No voiceprints on the
/// phone, so every speaker is "Speaker N" with certainty `unknown`. Runs nothing locally
/// (FR-007).
struct MeetingSummarizer: Sendable {
  enum Outcome: Sendable, Equatable {
    case adopted
    /// The server could not be reached or was busy: try again later.
    case waiting
    /// The run failed for good (the category is on the run row) or the meeting has no
    /// final transcript.
    case failed(AnalysisFailureCategory)
  }

  let transcripts: TranscriptStore
  let meetings: MeetingStore
  let store: AnalysisStore
  let transport: any AnalysisTransporting
  /// The server's origin; requests go over the channel (`viaRemoteChannel`).
  let endpoint: @Sendable () async -> RewriteEndpoint?
  var policy = AnalysisPolicy()
  var now: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }

  /// The evidence one run reads, taken once at admission.
  struct Evidence: Sendable {
    var passID: UUID
    var meeting: Meeting?
    var segments: [EvidenceSegment]
    var participants: [EvidenceParticipant]
    var notes: [NoteParagraph]
    var language: AnalysisLanguage
  }

  func run(meetingID: UUID) async -> Outcome {
    guard let endpoint = await endpoint() else { return .waiting }
    let evidence: Evidence
    let run: AnalysisRun
    do {
      guard let loaded = try await loadEvidence(meetingID: meetingID) else {
        return .failed(.notEligible)
      }
      evidence = loaded
      let version = EvidenceVersion.compute(
        meetingID: meetingID, passID: loaded.passID, segments: loaded.segments,
        participants: loaded.participants, notes: loaded.notes, languageOutput: loaded.language,
        preserveTerms: true, chunkBudgetBytes: policy.chunkBudgetBytes)
      run = try await store.admit(
        meetingID: meetingID, trigger: .automatic, evidence: version, passID: loaded.passID,
        policy: policy, now: now())
      try await store.recordInferencePath(runID: run.id, path: .server)
      _ = try await store.start(runID: run.id, now: now())
    } catch {
      return .failed(.persistenceFailure)
    }
    do {
      try await execute(run: run, evidence: evidence, endpoint: transport.pinned(endpoint))
      return .adopted
    } catch let failure as AnalysisFailure {
      if failure.category == .timeout {
        try? await store.timeOut(runID: run.id, now: now())
      } else {
        try? await store.fail(
          runID: run.id, category: failure.category, detail: failure.detail, now: now())
      }
      return failure.detail == RemoteAnalysisTransport.waitingDetail
        ? .waiting : .failed(failure.category)
    } catch {
      try? await store.cancel(runID: run.id, now: now())
      return error is CancellationError ? .waiting : .failed(.persistenceFailure)
    }
  }

  // MARK: Evidence

  /// Final segments of the current pass with each one's speaker root, the accepted
  /// run's speakers as participants, and the notes. Nil without a final transcript.
  func loadEvidence(meetingID: UUID) async throws -> Evidence? {
    guard let transcription = try await transcripts.transcription(meetingID: meetingID),
      transcription.state == .final, let passID = transcription.passID
    else { return nil }
    var segments: [EvidenceSegment] = []
    var after: Int?
    while true {
      let page = try await transcripts.labeledPage(
        meetingID: meetingID, finality: .final, after: after, limit: 200)
      segments += page.filter { $0.segment.passID == passID }.map { labeled in
        let speaker: EffectiveSpeaker
        switch labeled.label?.kind {
        case .speaker(let root): speaker = .speaker(root)
        case .overlapping: speaker = .ambiguous
        case .unknown, nil: speaker = .unknown
        }
        let segment = labeled.segment
        return EvidenceSegment(
          id: segment.id, ordinal: segment.ordinal, startMs: segment.startMs,
          endMs: segment.endMs, speaker: speaker, text: segment.normalizedText)
      }
      guard page.count == 200, let last = page.last?.segment.ordinal else { break }
      after = last
    }
    let roots = (try await transcripts.acceptedSpeakers(meetingID: meetingID))?.speakers
      .filter { $0.mergedInto == nil } ?? []
    let participants = roots.map { root in
      // A renamed speaker is the owner's own label for them (FR-014 `local_name`).
      EvidenceParticipant(
        speakerID: root.id, certainty: root.displayName == nil ? .unknown : .localName,
        origin: "none", name: root.displayName,
        label: SpeakerLabelText.text(
          source: root.source, ordinal: root.labelOrdinal, name: nil, inRoom: root.inRoom))
    }
    let notes = Self.paragraphs(try await meetings.notes(meetingID: meetingID)?.text ?? "")
    let meeting = try await meetings.meeting(id: meetingID)
    let language = LanguagePolicy.resolve(
      segments: segments, sampleBytes: policy.languageSampleBytes,
      meetingLanguage: meeting?.language, transcriptPipeline: transcription.pipelineVersion)
    return Evidence(
      passID: passID, meeting: meeting, segments: segments, participants: participants,
      notes: notes, language: language)
  }

  /// Blank-line paragraphs, trimmed and numbered from 1, the way the Mac hashes them.
  static func paragraphs(_ text: String) -> [NoteParagraph] {
    text.components(separatedBy: "\n")
      .split { $0.trimmingCharacters(in: .whitespaces).isEmpty }
      .map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
      .enumerated().map { index, paragraph in
        NoteParagraph(
          ordinal: index + 1, text: paragraph, hash: EvidenceVersion.hash(paragraph: paragraph))
      }
  }

  // MARK: Requests

  private func execute(run: AnalysisRun, evidence: Evidence, endpoint: RewriteEndpoint)
    async throws
  {
    let health = try await transport.health(endpoint: endpoint)
    if let schema = health.resultSchemaVersion, schema != AnalysisBounds.schemaVersion {
      throw AnalysisFailure(.unsupportedVersion, detail: "result_schema_version")
    }
    let effective = policy.lowered(by: health)
    let plan = try AnalysisChunkPlanner.plan(
      segments: evidence.segments, notes: evidence.notes, policy: effective)
    try await store.recordPlan(runID: run.id, chunkCount: plan.chunks.count)
    var checked = AnalysisEvidence(
      meetingID: run.meetingID, segmentIDs: Set(evidence.segments.map(\.id)),
      segmentText: Dictionary(uniqueKeysWithValues: evidence.segments.map { ($0.id, $0.text) }),
      notes: evidence.notes, participants: evidence.participants)
    checked.meetingStartedAtMs = evidence.meeting?.startedAt ?? evidence.meeting?.createdAt
    checked.meetingTimeZone = evidence.meeting?.timeZone

    let final: AnalysisEvent.ResultPayload
    if plan.isFull {
      final = try await send(
        request(run, evidence, stage: .full, segments: evidence.segments, notes: evidence.notes),
        endpoint: endpoint, runID: run.id)
    } else {
      var inputs: [AnalysisResult] = []
      for chunk in plan.chunks {
        let window = evidence.segments.filter {
          $0.ordinal >= chunk.firstOrdinal && $0.ordinal < chunk.lastOrdinal
        }
        let payload = try await send(
          request(
            run, evidence, stage: .chunk, chunk: .init(index: chunk.index, count: plan.chunks.count),
            segments: window),
          endpoint: endpoint, runID: run.id)
        inputs.append(payload.analysis)
      }
      var last: AnalysisEvent.ResultPayload?
      for (level, count) in plan.synthesisCounts.enumerated() {
        var outputs: [AnalysisResult] = []
        for start in stride(from: 0, to: inputs.count, by: effective.partialsPerSynthesis) {
          let group = Array(
            inputs[start..<min(start + effective.partialsPerSynthesis, inputs.count)])
          let isFinal = level == plan.synthesisCounts.count - 1 && outputs.count == count - 1
          let payload = try await send(
            request(
              run, evidence, stage: .synthesis, notes: isFinal ? evidence.notes : nil,
              partials: group),
            endpoint: endpoint, runID: run.id)
          outputs.append(payload.analysis)
          if isFinal { last = payload }
        }
        inputs = outputs
      }
      guard let last else { throw AnalysisFailure(.malformedResponse, detail: "no_result") }
      final = last
    }
    let (validated, counts) = try AnalysisValidator.validate(
      result: final.analysis, against: checked, policy: effective)
    let promptVersions = health.promptVersions.sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    try await store.adopt(
      runID: run.id, result: validated, counts: counts,
      identity: RunIdentity(
        serverVersion: final.server?.version ?? health.serverVersion ?? "",
        protocolVersion: 1, schemaVersion: final.analysis.schemaVersion,
        backendKind: final.backend?.kind ?? health.backend?.kind ?? "",
        backendModel: final.backend?.model ?? health.backend?.model ?? "",
        promptVersions: promptVersions,
        pipelineVersion: final.pipelineVersion ?? AnalysisPolicy.pipelineVersion),
      now: now())
  }

  func request(
    _ run: AnalysisRun, _ evidence: Evidence, stage: AnalysisStage,
    chunk: AnalysisRequest.Chunk? = nil, segments: [EvidenceSegment]? = nil,
    notes: [NoteParagraph]? = nil, partials: [AnalysisResult]? = nil
  ) -> AnalysisRequest {
    func clipped(_ text: String, _ bytes: Int) -> String {
      String(decoding: text.utf8.prefix(bytes), as: UTF8.self)
    }
    let meeting = evidence.meeting
    let started = meeting?.startedAt ?? meeting?.createdAt ?? 0
    return AnalysisRequest(
      requestID: UUID(), runID: run.id, stage: stage, chunk: chunk,
      meeting: .init(
        id: run.meetingID,
        title: clipped(meeting?.displayTitle ?? "Meeting", AnalysisBounds.maxTitleBytes),
        startedAt: Self.rfc3339(ms: started),
        durationMs: meeting?.wallClockMs ?? 0,
        timeZone: clipped(
          meeting?.timeZone ?? TimeZone.current.identifier, AnalysisBounds.maxTimeZoneBytes),
        languagePolicy: LanguagePolicy.requestValue(output: evidence.language)),
      participants: evidence.participants.map {
        .init(
          speakerID: $0.speakerID, certainty: $0.certainty, origin: $0.origin,
          knownSpeakerID: nil,
          name: $0.certainty.mayBeNamed
            ? $0.name.map { clipped($0, AnalysisBounds.maxParticipantNameBytes) } : nil,
          label: $0.label.map { clipped($0, AnalysisBounds.maxParticipantNameBytes) })
      },
      segments: segments?.map { segment in
        var speaker: UUID?
        if case .speaker(let id) = segment.speaker { speaker = id }
        return .init(
          id: segment.id, startMs: segment.startMs, endMs: segment.endMs, speakerID: speaker,
          text: segment.text)
      },
      notes: notes?.map { .init(ordinal: $0.ordinal, text: $0.text) }, partials: partials)
  }

  /// RFC 3339 with the local offset, as the Mac sends it.
  static func rfc3339(ms: Int64) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
    formatter.timeZone = TimeZone.current
    return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1_000))
  }

  /// One request to its `result`; anything else fails the run.
  private func send(_ request: AnalysisRequest, endpoint: RewriteEndpoint, runID: UUID)
    async throws -> AnalysisEvent.ResultPayload
  {
    var result: AnalysisEvent.ResultPayload?
    var sizes = (request: 0, response: 0)
    for try await item in transport.analyze(
      request: request, endpoint: endpoint, timeout: policy.perRequestTimeout)
    {
      switch item {
      case .event(.result(let payload)):
        guard payload.runID == nil || payload.runID == runID.uuidString else {
          throw AnalysisFailure(.malformedResponse, detail: "run_id")
        }
        result = payload
      case .event(.error(_, let code)):
        throw AnalysisFailure(AnalysisFailureCategory.forServerCode(code), detail: code)
      case .completed(let requestBytes, let responseBytes):
        sizes = (requestBytes, responseBytes)
      default: break
      }
    }
    try Task.checkCancellation()
    try await store.recordRequest(
      runID: runID, inputBytes: sizes.request, outputBytes: sizes.response, retried: false,
      preempted: false)
    guard let result else { throw AnalysisFailure(.malformedResponse, detail: "no_result") }
    guard result.analysis.language == request.meeting.languagePolicy.output else {
      throw AnalysisFailure(.malformedResponse, detail: "language_policy")
    }
    return result
  }
}
