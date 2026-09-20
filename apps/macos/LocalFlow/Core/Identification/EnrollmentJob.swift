import Foundation
import OSLog

/// What the sheet asked for on Save (research R8).
struct EnrollmentRequest: Sendable, Equatable {
  enum Target: Sendable, Equatable {
    /// Remember: a new profile with this name.
    case newProfile(name: String)
    /// Also remember, or a picked profile: samples for an existing known speaker.
    case existing(knownSpeakerID: UUID)
  }
  let meetingID: UUID
  /// The display root whose regions are embedded.
  let rootID: UUID
  let target: Target
  /// `newProfileCreated`, `manualProfileSelection`, `userConfirmation` or
  /// `manualCorrection`; ignored for the local-user profile.
  let origin: IdentityOrigin
  let consent: SampleConsent
  /// Only this track's turns feed the samples (microphone for the local user).
  let track: MeetingTrackKind
  var isLocalUser = false
}

enum EnrollmentOutcome: Sendable, Equatable {
  case stored(Int)
  case noUsableSample
  case disabled
  case failed(IdentificationFailureCategory)
}

/// One enrollment (contracts/identification-pipeline.md "Enrollment algorithm"): the
/// profile and the identity row commit first, then regions are read and embedded one
/// at a time under a lease of its own, then the samples are stored with their consent.
actor EnrollmentJob {
  enum Result: Sendable, Equatable {
    case outcome(EnrollmentOutcome, knownSpeakerID: UUID?)
    /// Another lease holds the model; try again later.
    case busy
    /// A speech workload revoked the lease; try again later.
    case preempted
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

  func run(_ request: EnrollmentRequest, progress: (@Sendable (Int, Int) -> Void)? = nil) async
    -> Result
  {
    // 1. Profile and identity row first, so a failure leaves "0 samples" and a name.
    let knownSpeakerID: UUID
    do {
      switch request.target {
      case .newProfile(let name):
        let row = try await store.enroll(
          meetingID: request.meetingID, speakerID: request.isLocalUser ? nil : request.rootID,
          name: name, isLocalUser: request.isLocalUser, origin: request.origin,
          now: clock.nowMilliseconds)
        knownSpeakerID = row.id
      case .existing(let id):
        knownSpeakerID = id
        if !request.isLocalUser {
          try await store.link(
            meetingID: request.meetingID, speakerID: request.rootID, to: id,
            origin: request.origin, now: clock.nowMilliseconds)
        }
      }
    } catch let error as IdentityStore.Error {
      switch error {
      case .capacity, .persistenceCapacity:
        return .outcome(.failed(.persistenceCapacity), knownSpeakerID: nil)
      default: return .outcome(.failed(.persistenceFailure), knownSpeakerID: nil)
      }
    } catch {
      return .outcome(.failed(.persistenceFailure), knownSpeakerID: nil)
    }
    if Task.isCancelled { return .outcome(.failed(.interrupted), knownSpeakerID: knownSpeakerID) }
    // 2. Regions from the root's turns on its track.
    let plan: [VoiceRegion]
    let detail: MeetingDetail
    let bases: [Int: (Int64, Int64?)]
    do {
      guard let loaded = try await meetings.detail(id: request.meetingID),
        let diarization = try await speakers.diarization(meetingID: request.meetingID),
        let runID = diarization.acceptedRunID
      else { return .outcome(.failed(.audioMissing), knownSpeakerID: knownSpeakerID) }
      detail = loaded
      let members =
        try await transcripts.acceptedSpeakers(meetingID: request.meetingID)?
        .speakers.filter { $0.mergedInto == request.rootID }.map(\.id) ?? []
      let root = RegionExtractor.Root(id: request.rootID, members: members, source: .remote)
      let length = max(detail.meeting.recordedMs, 1)
      let turns = try await RegionExtractor.turns(of: runID, lengthMs: length, speakers: speakers)
      plan = RegionExtractor.regions(
        for: root, turns: turns, track: request.track, lengthMs: length, limits: .enroll)
      bases = RegionExtractor.transcriptBases(
        try await transcripts.transcription(meetingID: request.meetingID)?.analysisDescriptor)
    } catch {
      return .outcome(.failed(.persistenceFailure), knownSpeakerID: knownSpeakerID)
    }
    guard !plan.isEmpty else { return .outcome(.noUsableSample, knownSpeakerID: knownSpeakerID) }
    // 3. The lease, one region at a time, then release.
    let lease: ModelLease
    do {
      lease = try await lifecycle.acquire(
        session: request.meetingID, workload: .speakerIdentification)
    } catch {
      if Task.isCancelled { return .outcome(.failed(.interrupted), knownSpeakerID: knownSpeakerID) }
      if let category = error as? IdentificationFailureCategory {
        return .outcome(.failed(category), knownSpeakerID: knownSpeakerID)
      }
      switch error as? DictationFailure {
      case .busy: return .busy
      case .cancelled: return .preempted
      case .modelUnavailable:
        return .outcome(.failed(.modelUnavailable), knownSpeakerID: knownSpeakerID)
      default: return .outcome(.failed(.modelLoadFailure), knownSpeakerID: knownSpeakerID)
      }
    }
    let started = clock.monotonicNanoseconds
    let extracted: [RegionExtractor.Extracted]
    let tally: RegionExtractor.Tally
    do {
      let reader = VoiceRegionReader(storageRoot: storageRoot, detail: detail, bases: bases)
      (extracted, tally) = try await RegionExtractor.extract(
        [(request.rootID, plan)], reader: reader, lifecycle: lifecycle, lease: lease,
        progress: progress)
      try await lifecycle.finish(lease)
    } catch {
      do { try await lifecycle.finish(lease) } catch { await lifecycle.cancelAndJoin(lease) }
      if Task.isCancelled || error is CancellationError {
        return .outcome(.failed(.interrupted), knownSpeakerID: knownSpeakerID)
      }
      if error is RegionExtractor.Preempted { return .preempted }
      if let failure = error as? RegionExtractor.Failure {
        logger.notice(
          "enrollment failed category=\(failure.category.rawValue, privacy: .public)")
        return .outcome(.failed(failure.category), knownSpeakerID: knownSpeakerID)
      }
      return .outcome(.failed(.runtimeFailure), knownSpeakerID: knownSpeakerID)
    }
    // 4. Samples with the consent that created them; the store applies the cap.
    let drafts = extracted.map { item in
      VoiceSampleDraft(
        vector: item.vector, identity: identity,
        pipelineVersion: IdentificationPipelineVersion.current,
        qualityLabel: VoiceRegionSelector.qualityLabel(
          durationMs: item.region.durationMs, engineQuality: item.region.engineQuality),
        qualityScore: VoiceRegionSelector.qualityScore(
          durationMs: item.region.durationMs, engineQuality: item.region.engineQuality),
        engineQuality: item.region.engineQuality, speechMs: item.region.durationMs,
        track: item.region.track, startMs: item.region.startMs, endMs: item.region.endMs,
        sourceMeetingID: request.meetingID, sourceSpeakerID: request.rootID)
    }
    guard !drafts.isEmpty else {
      record(stored: 0, tally: tally, started: started)
      return .outcome(.noUsableSample, knownSpeakerID: knownSpeakerID)
    }
    do {
      let stored = try await store.addSamples(
        knownSpeakerID: knownSpeakerID, drafts: drafts, consent: request.consent,
        now: clock.nowMilliseconds)
      record(stored: stored, tally: tally, started: started)
      return .outcome(
        stored > 0 ? .stored(stored) : .noUsableSample, knownSpeakerID: knownSpeakerID)
    } catch let error as IdentityStore.Error {
      switch error {
      case .rejectedSource: return .outcome(.noUsableSample, knownSpeakerID: knownSpeakerID)
      case .persistenceCapacity, .capacity:
        return .outcome(.failed(.persistenceCapacity), knownSpeakerID: knownSpeakerID)
      default: return .outcome(.failed(.persistenceFailure), knownSpeakerID: knownSpeakerID)
      }
    } catch {
      return .outcome(.failed(.persistenceFailure), knownSpeakerID: knownSpeakerID)
    }
  }

  /// FR-037: counts and durations only.
  private func record(stored: Int, tally: RegionExtractor.Tally, started: UInt64) {
    guard let recorder else { return }
    recorder.record(
      phase: .identifying, durationNanoseconds: clock.monotonicNanoseconds &- started,
      metric: .identificationDuration)
    let counts: [(ResourceRecorder.Metric, Int)] = [
      (.identificationRegionsExtracted, tally.extracted),
      (.identificationRegionsRejected, tally.rejected + tally.missing),
      (.enrollmentSamplesStored, stored),
    ]
    for (metric, value) in counts {
      recorder.record(
        phase: .identifying, metric: metric, itemCount: UInt32(clamping: max(0, value)))
    }
  }
}
