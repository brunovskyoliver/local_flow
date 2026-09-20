import Foundation
import OSLog

/// One identification run over a meeting (contracts/identification-pipeline.md "Run
/// algorithm"). Profiles are loaded once, every remote root's query regions are read in
/// one pass and embedded under a lease of its own, the lease is finished, then each root
/// is decided and the run adopted in one transaction. Transcript rows, turns, samples
/// and audio are only read.
actor MeetingIdentifier {
  enum Outcome: Sendable, Equatable {
    case succeeded(IdentificationRun)
    case failed(IdentificationFailureCategory)
    /// A speech workload revoked the lease; the run is `pending` again.
    case preempted
    /// The task was cancelled (user Cancel or meeting deletion); the run row is gone.
    case cancelled
    /// Another lease or an installation holds the model; the run stays `pending`.
    case busy
    /// No pending run for the meeting.
    case nothingToRun
    /// Past search: no remote root was Unknown, so nothing was admitted.
    case skipped
  }

  private let store: any IdentityStoring
  private let speakers: any SpeakerStoring
  private let transcripts: any TranscriptStoring
  private let meetings: any MeetingStoring
  private let storageRoot: MeetingStorageRoot
  private let lifecycle: ModelLifecycleCoordinator
  private let identity: VoiceModelIdentity
  private let clock: any MeetingClock
  private let recorder: ResourceRecorder?
  private let logger = Logger(subsystem: "org.localflow.LocalFlow", category: "identification")
  private var shuttingDown = false

  init(
    store: any IdentityStoring, speakers: any SpeakerStoring, transcripts: any TranscriptStoring,
    meetings: any MeetingStoring, storageRoot: MeetingStorageRoot,
    lifecycle: ModelLifecycleCoordinator, identity: VoiceModelIdentity,
    clock: any MeetingClock = SystemMeetingClock(), recorder: ResourceRecorder? = nil
  ) {
    self.store = store
    self.speakers = speakers
    self.transcripts = transcripts
    self.meetings = meetings
    self.storageRoot = storageRoot
    self.lifecycle = lifecycle
    self.identity = identity
    self.clock = clock
    self.recorder = recorder
  }

  var thresholdPolicy: String { IdentificationThresholds.policyVersion(for: identity) }

  // MARK: Admission

  /// A `pending` run against the meeting's accepted diarization run. For a past search,
  /// a meeting whose remote roots all have a named or Confirmed identity is skipped.
  func admit(meetingID: UUID, trigger: IdentificationTrigger) async throws -> IdentificationRun? {
    if trigger == .pastSearch {
      let identities = try await store.identities(meetingID: meetingID)
      let roots = try await speakers.speakerSummaries(meetingID: meetingID)
        .filter { $0.source == .remote }
      let unknown = roots.contains { root in
        let state = identities[root.id]?.state ?? .unknown
        return state == .unknown
      }
      guard unknown else { return nil }
    }
    return try await store.admit(
      meetingID: meetingID, trigger: trigger, identity: identity, policy: thresholdPolicy,
      now: clock.nowMilliseconds)
  }

  // MARK: Run

  private struct Context {
    let run: IdentificationRun
    let roots: [RegionExtractor.Root]
    let startedNs: UInt64
  }

  func run(meetingID: UUID, progress: (@Sendable (Int, Int) -> Void)? = nil) async -> Outcome {
    let pending: IdentificationRun
    do {
      guard let row = try await store.identification(meetingID: meetingID),
        let current = row.currentRunID, let run = try await store.run(id: current),
        run.state == .pending
      else { return .nothingToRun }
      pending = run
    } catch {
      return .nothingToRun
    }
    // 1. The accepted diarization run must be the one the run was admitted against.
    let roots: [RegionExtractor.Root]
    let detail: MeetingDetail
    do {
      guard let diarization = try await speakers.diarization(meetingID: meetingID),
        diarization.acceptedRunID == pending.diarizationRunID
      else { return await fail(pending.id, .diarizationChanged) }
      guard let loaded = try await meetings.detail(id: meetingID) else {
        return await fail(pending.id, .audioMissing)
      }
      detail = loaded
      // Remote display roots only: "You" is never queried (FR-016).
      roots = try await speakers.speakerSummaries(meetingID: meetingID)
        .filter { $0.source == .remote }
        .map { .init(id: $0.id, members: $0.includes.map(\.id), source: $0.source) }
    } catch {
      return await fail(pending.id, .persistenceFailure)
    }
    guard let thresholds = IdentificationThresholds.current(for: identity) else {
      return await fail(pending.id, .modelUnavailable)
    }
    // 2. Profiles; none means every remote root is Unknown with no lease.
    let profiles: [CandidateProfile]
    do {
      profiles = try await store.profiles(compatibleWith: identity)
    } catch {
      return await fail(pending.id, .persistenceFailure)
    }
    let candidates = profiles.filter { !$0.isLocalUser }
    if candidates.isEmpty {
      do {
        let decisions = Dictionary(
          uniqueKeysWithValues: roots.map { ($0.id, IdentityMatcher.Decision.unknown) })
        let completed = try await store.complete(
          runID: pending.id, decisions: decisions, now: clock.nowMilliseconds)
        record(completed, tally: .init(), comparisons: 0, startedNs: clock.monotonicNanoseconds)
        return .succeeded(completed)
      } catch {
        return await end(pending.id, lease: nil, error: error)
      }
    }
    // 3. The lease, before `start`, so a busy model leaves the run pending.
    let lease: ModelLease
    do {
      lease = try await lifecycle.acquire(session: meetingID, workload: .speakerIdentification)
    } catch {
      if Task.isCancelled { return await cancel(pending.id) }
      if let category = error as? IdentificationFailureCategory {
        return await fail(pending.id, category)
      }
      switch error as? DictationFailure {
      case .busy: return .busy
      case .cancelled: return .preempted
      case .modelUnavailable: return await fail(pending.id, .modelUnavailable)
      default: return await fail(pending.id, .modelLoadFailure)
      }
    }
    let context: Context
    do {
      let started = try await store.start(runID: pending.id, now: clock.nowMilliseconds)
      context = Context(run: started, roots: roots, startedNs: clock.monotonicNanoseconds)
    } catch {
      try? await lifecycle.finish(lease)
      return await fail(pending.id, .persistenceFailure)
    }
    // 4. Query regions per root, read once, embedded as they complete.
    let extracted: [RegionExtractor.Extracted]
    let tally: RegionExtractor.Tally
    do {
      guard let diarization = try await speakers.diarization(meetingID: meetingID),
        let runID = diarization.acceptedRunID
      else { throw RegionExtractor.Failure(.diarizationChanged) }
      let length = max(detail.meeting.recordedMs, 1)
      let turns = try await RegionExtractor.turns(of: runID, lengthMs: length, speakers: speakers)
      let plan = roots.map { root in
        (
          root.id,
          RegionExtractor.regions(
            for: root, turns: turns, track: nil, lengthMs: length, limits: .query)
        )
      }
      let bases = RegionExtractor.transcriptBases(
        try await transcripts.transcription(meetingID: meetingID)?.analysisDescriptor)
      let reader = VoiceRegionReader(storageRoot: storageRoot, detail: detail, bases: bases)
      if plan.allSatisfy({ $0.1.isEmpty }) {
        extracted = []
        tally = .init()
      } else {
        (extracted, tally) = try await RegionExtractor.extract(
          plan, reader: reader, lifecycle: lifecycle, lease: lease, progress: progress)
      }
      try await lifecycle.finish(lease)
    } catch {
      return await end(context.run.id, lease: lease, error: error)
    }
    // 5. After `finish` there is no lease to revoke; decide, record, adopt.
    do {
      try await store.recordRegions(
        runID: context.run.id, extracted: tally.extracted, rejected: tally.rejected + tally.missing)
      let rejected = try await store.rejectedCandidates(meetingID: meetingID)
      var decisions: [UUID: IdentityMatcher.Decision] = [:]
      var drafts: [MatchCandidateDraft] = []
      for root in roots {
        let query = extracted.filter { $0.root == root.id }.map {
          QueryRegion(vector: $0.vector, weightMs: $0.region.durationMs)
        }
        let decision = IdentityMatcher.decide(
          query: query, profiles: profiles, rejected: rejected[root.id] ?? [],
          thresholds: thresholds)
        decisions[root.id] = decision
        drafts += decision.candidates.map {
          MatchCandidateDraft(
            meetingSpeakerID: root.id, knownSpeakerID: $0.knownSpeakerID, score: $0.score,
            tier: $0.tier, reasons: $0.reasons, sampleCount: $0.sampleCount,
            supportCount: $0.supportCount)
        }
      }
      try Task.checkCancellation()
      guard drafts.count <= IdentityStore.candidatesPerRun else {
        throw RegionExtractor.Failure(.persistenceCapacity)
      }
      for start in stride(from: 0, to: drafts.count, by: DiarizationConstants.writeBatch) {
        try await store.appendCandidates(
          runID: context.run.id,
          rows: Array(drafts[start..<min(start + DiarizationConstants.writeBatch, drafts.count)]))
      }
      guard
        try await speakers.diarization(meetingID: meetingID)?.acceptedRunID
          == context.run.diarizationRunID
      else { throw RegionExtractor.Failure(.diarizationChanged) }
      let completed = try await store.complete(
        runID: context.run.id, decisions: decisions, now: clock.nowMilliseconds)
      logger.notice(
        "identification complete roots=\(completed.clusterCount) recognized=\(completed.recognizedCount) suggested=\(completed.suggestedCount) unknown=\(completed.unknownCount)"
      )
      record(completed, tally: tally, comparisons: drafts.count, startedNs: context.startedNs)
      return .succeeded(completed)
    } catch {
      return await end(context.run.id, lease: nil, error: error)
    }
  }

  /// FR-037: the run's numbers, never its names, vectors or ids.
  private func record(
    _ run: IdentificationRun, tally: RegionExtractor.Tally, comparisons: Int, startedNs: UInt64
  ) {
    guard let recorder else { return }
    recorder.record(
      phase: .identifying, durationNanoseconds: clock.monotonicNanoseconds &- startedNs,
      metric: .identificationDuration)
    let counts: [(ResourceRecorder.Metric, Int)] = [
      (.identificationRegionsExtracted, tally.extracted),
      (.identificationRegionsRejected, tally.rejected + tally.missing),
      (.identificationComparisons, comparisons),
      (.identificationRecognized, run.recognizedCount),
      (.identificationSuggested, run.suggestedCount),
      (.identificationUnknown, run.unknownCount),
    ]
    for (metric, value) in counts {
      recorder.record(
        phase: .identifying, metric: metric, itemCount: UInt32(clamping: max(0, value)))
    }
  }

  // MARK: Endings

  private func end(_ runID: UUID, lease: ModelLease?, error: Swift.Error) async -> Outcome {
    if let lease {
      do { try await lifecycle.finish(lease) } catch { await lifecycle.cancelAndJoin(lease) }
    }
    if Task.isCancelled || error is CancellationError { return await cancel(runID) }
    let revoked =
      error as? DictationFailure == .cancelled || error as? DictationFailure == .staleLease
    if error is RegionExtractor.Preempted || revoked {
      do {
        try await store.requeue(runID: runID)
        return .preempted
      } catch {
        return await fail(runID, .persistenceFailure)
      }
    }
    if let failure = error as? RegionExtractor.Failure {
      return await fail(runID, failure.category)
    }
    if let error = error as? IdentityStore.Error {
      switch error {
      case .capacity, .persistenceCapacity: return await fail(runID, .persistenceCapacity)
      default: return await fail(runID, .persistenceFailure)
      }
    }
    return await fail(runID, .persistenceFailure)
  }

  private func cancel(_ runID: UUID) async -> Outcome {
    if shuttingDown {
      // Quit is not Cancel: a started run is interrupted, a pending one resumes next launch.
      if (try? await store.run(id: runID))??.state == .running {
        try? await store.interrupt(runID: runID, now: clock.nowMilliseconds)
      }
    } else {
      try? await store.cancel(runID: runID)
    }
    return .cancelled
  }

  /// Application quit: the next cancellation keeps the run for launch reconciliation.
  func prepareForShutdown() { shuttingDown = true }

  private func fail(_ runID: UUID, _ category: IdentificationFailureCategory) async -> Outcome {
    try? await store.fail(runID: runID, category: category, detail: nil, now: clock.nowMilliseconds)
    logger.notice("identification failed category=\(category.rawValue, privacy: .public)")
    recorder?.record(
      phase: .identifying, metric: .identificationFailure, itemCount: 1,
      meetingKey: category.rawValue)
    return .failed(category)
  }
}
