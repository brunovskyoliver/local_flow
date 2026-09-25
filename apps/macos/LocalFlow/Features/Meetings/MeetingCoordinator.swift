import AppKit
import Foundation
import OSLog
import Observation

/// Owns at most one meeting. Every transition is written through the store
/// before it is published; the two sources and two workers of a stretch are
/// released on every pause, stop, sleep and failure. Polls run on the injected
/// clock: 250 ms for storage latches and device changes; at most 1 Hz for source
/// failures (the system source preflights screen-capture access) and the
/// microphone authorization; 1 Hz for the elapsed display; 10 s for RSS.
@MainActor @Observable
final class MeetingCoordinator {
  enum StartOutcome: Equatable, Sendable {
    case started(UUID)
    case alreadyActive(UUID)
    case refused(String)
  }

  struct Dependencies {
    var store: any MeetingStoring
    var writer: any SegmentWriting
    var permissions: MeetingPermissions
    var clock: any MeetingClock
    var recorder: ResourceRecorder?
    var storageRoot: MeetingStorageRoot
    var sourceFactory: @Sendable (MeetingTrackKind) -> any MeetingAudioSourcing
    var isDictationBusy: @MainActor () -> Bool = { false }
    /// Resolves once launch reconciliation has finished.
    var reconciliationGate: @Sendable () async -> Void = {}
    var sleepCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    var options = MeetingRuntimeOptions()
    var transcription: (any MeetingTranscriptionObserving)?
  }

  static let pollInterval: Duration = .milliseconds(250)
  /// Source failure and permission checks are TCC queries; they run at most this often.
  static let permissionIntervalMs: Int64 = 1_000
  static let elapsedInterval: Duration = .seconds(1)
  static let rssInterval: Duration = .seconds(10)
  static let blockingFreeBytes: Int64 = 500_000_000
  static let warningFreeBytes: Int64 = 2_000_000_000

  /// The one published value (FR-006). Stays with its terminal state until the
  /// user dismisses it or starts the next meeting.
  private(set) var status: MeetingStatus?
  private(set) var reconciliationComplete = false
  /// Refusal text with no meeting row (permissions, preflight, dictation busy).
  private(set) var refusal: String?
  private(set) var refusalPermission: MeetingTrackKind?
  private(set) var notesEditor: MeetingNotesEditor?
  /// Feature 011: the live notes editor reports saved paragraphs as evidence.
  @ObservationIgnored weak var intelligence: (any IntelligenceObserving)?
  /// Bumped after every persisted change the library lists (state, title, tracks,
  /// segments). Recording heartbeats do not bump it: they change nothing the list
  /// or the open note shows beyond `status.droppedFrames`.
  private(set) var version = 0
  /// Recorded time, ticked at 1 Hz while recording. It lives outside `status` so
  /// only the small views that print it redraw every second.
  let elapsed = MeetingElapsed()
  var recordedElapsed: Duration { elapsed.recorded }

  private struct TrackRuntime {
    let trackID: UUID
    var source: any MeetingAudioSourcing
    var ring: MeetingSampleRing
    var worker: MeetingTrackWorker
    var segment: MeetingSegment
    var format: MeetingSourceFormat
    var sampledDroppedFrames: Int64 = 0
  }

  @ObservationIgnored private let deps: Dependencies
  @ObservationIgnored private var meeting: Meeting?
  @ObservationIgnored private var trackIDs: [MeetingTrackKind: UUID] = [:]
  @ObservationIgnored private var runtimes: [MeetingTrackKind: TrackRuntime] = [:]
  @ObservationIgnored private var sequences: [MeetingTrackKind: Int] = [:]
  @ObservationIgnored private var trackOffsets: [MeetingTrackKind: Int64] = [:]
  @ObservationIgnored private var failedTracks: [MeetingTrackKind: MeetingFailureReason] = [:]
  @ObservationIgnored private var recordedBase: Int64 = 0
  @ObservationIgnored private var cumulativeDroppedFrames: Int64 = 0
  @ObservationIgnored private var stretchStartedAt: Int64 = 0
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var lastPermissionCheckMs: Int64?
  @ObservationIgnored private var elapsedTask: Task<Void, Never>?
  @ObservationIgnored private var rssTask: Task<Void, Never>?
  @ObservationIgnored private var sleepObserver: SleepObserver?
  @ObservationIgnored private var busy = false
  @ObservationIgnored private let logger = Logger(
    subsystem: "org.localflow.LocalFlow", category: "meetings")

  init(dependencies: Dependencies) {
    deps = dependencies
    sleepObserver = SleepObserver(center: dependencies.sleepCenter) { [weak self] in
      guard let self, self.status?.state == .recording else { return }
      Task { await self.pause(reason: .systemSleep) }
    }
  }

  deinit {
    pollTask?.cancel()
    elapsedTask?.cancel()
    rssTask?.cancel()
  }

  var isActive: Bool { status?.state.isActive ?? false }
  var canStart: Bool { reconciliationComplete && !isActive && !busy }
  var activeMeetingID: UUID? { isActive ? status?.id : nil }

  func markReconciliationComplete() { reconciliationComplete = true }

  /// Clears a terminal status banner.
  func dismiss() {
    guard !isActive else { return }
    status = nil
    refusal = nil
    refusalPermission = nil
    notesEditor = nil
  }

  /// Title edits are revision-checked against the row the coordinator holds.
  func setTitle(_ title: String) async throws {
    guard let meeting else { return }
    let revision = try await deps.store.setTitle(
      meetingID: meeting.id, title: title, revision: meeting.revision,
      now: deps.clock.nowMilliseconds)
    if let updated = try await deps.store.meeting(id: meeting.id) {
      self.meeting = updated
    } else {
      self.meeting?.revision = revision
    }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    status?.title = trimmed.isEmpty ? nil : trimmed
    version += 1
  }

  /// The library wrote the meeting row (title or language) outside the coordinator.
  /// Adopts the stored row when it is newer, so the published title stays current
  /// and the next revision-checked edit here does not fail as stale.
  func meetingDidChange(id: UUID) async {
    guard meeting?.id == id, let updated = try? await deps.store.meeting(id: id),
      let current = meeting, current.id == id, updated.revision > current.revision
    else { return }
    meeting = updated
    if status?.id == id, status?.title != updated.title || status?.language != updated.language {
      status?.title = updated.title
      status?.language = updated.language
    }
  }

  /// The language the final transcript decodes in; nil follows Settings. Stored on
  /// the meeting, so the final pass after Stop picks it up.
  func setLanguage(_ language: MeetingLanguage?) async throws {
    guard let meeting else { return }
    let revision = try await deps.store.setLanguage(
      meetingID: meeting.id, language: language, revision: meeting.revision,
      now: deps.clock.nowMilliseconds)
    if let updated = try await deps.store.meeting(id: meeting.id) {
      self.meeting = updated
    } else {
      self.meeting?.revision = revision
      self.meeting?.language = language
    }
    status?.language = language
    version += 1
  }

  // MARK: - Start

  func start(options: MeetingStartOptions = .init()) async -> StartOutcome {
    guard !busy else { return .refused("Meeting is busy") }
    if let id = activeMeetingID { return .alreadyActive(id) }
    guard !deps.isDictationBusy() else { return refuse(MeetingErrorMessage.dictationInProgress) }
    await deps.reconciliationGate()
    reconciliationComplete = true
    busy = true
    defer { busy = false }
    let startedAtNs = deps.clock.monotonicNanoseconds
    do {
      if let active = try await deps.store.activeMeeting() { return .alreadyActive(active.id) }
      switch await deps.permissions.check() {
      case .granted: break
      case .refused(let kind, let text):
        refusalPermission = kind
        return refuse(text)
      }
      // Storage preflight.
      do {
        try FileSegmentWriter.ensurePrivateDirectory(deps.storageRoot.url)
      } catch {
        return refuse(MeetingErrorMessage.text(for: .storageUnavailable))
      }
      let free = try deps.writer.freeSpace(at: deps.storageRoot.url)
      guard free >= Self.blockingFreeBytes else {
        return refuse(MeetingErrorMessage.notEnoughFreeSpace)
      }
      let warning = free < Self.warningFreeBytes ? MeetingErrorMessage.lowFreeSpaceWarning : nil
      // Formats are probed before the insert; probing does not start capture.
      var sources: [MeetingTrackKind: any MeetingAudioSourcing] = [:]
      var formats: [MeetingTrackKind: MeetingSourceFormat] = [:]
      var startFailures: [MeetingTrackKind: MeetingFailureReason] = [:]
      for kind in MeetingTrackKind.allCases {
        let source = deps.sourceFactory(kind)
        sources[kind] = source
        do { formats[kind] = try await source.probeFormat() } catch {
          startFailures[kind] = (error as? MeetingSourceFailure ?? .unknown(code: -1)).reason(
            for: kind)
        }
      }
      let now = deps.clock.nowMilliseconds
      let created = try await deps.store.create(now: now)
      let tracks = MeetingTrackKind.allCases.map { kind in
        MeetingTrack(
          id: UUID(), meetingID: created.id, kind: kind,
          channelCount: kind.encodedChannels(sourceChannels: formats[kind]?.channels ?? 2),
          bitrate: kind.bitrate)
      }
      trackIDs = Dictionary(uniqueKeysWithValues: tracks.map { ($0.kind, $0.id) })
      var preparing: [MeetingTransitionEffect] = [.insertTracks(tracks)]
      if let observer = deps.transcription {
        let initial = await observer.meetingWillStart(id: created.id, options: options)
        preparing.append(.insertTranscription(liveRequested: initial == .pending))
      }
      var current = try await deps.store.transition(
        id: created.id, to: .preparing, now: now, effects: preparing)
      recordTransition(.preparing)
      meeting = current
      status = MeetingStatus(
        id: created.id, state: .preparing, storageWarning: warning, createdAt: created.createdAt)
      elapsed.recorded = .zero
      status?.transcriptionRequested = deps.transcription != nil && options.transcription
      refusal = nil
      refusalPermission = nil
      failedTracks = [:]
      runtimes = [:]
      sequences = [:]
      trackOffsets = [:]
      recordedBase = 0
      cumulativeDroppedFrames = 0
      // Open one segment file per track; any open failure fails the meeting.
      var handles: [MeetingTrackKind: SegmentHandle] = [:]
      for kind in MeetingTrackKind.allCases where startFailures[kind] == nil {
        do {
          handles[kind] = try deps.writer.open(meetingID: created.id, kind: kind, sequence: 1)
        } catch {
          for handle in handles.values { deps.writer.discard(handle) }
          let detail =
            "open errno=\((error as? MeetingCaptureFailure).map { "\($0)" } ?? "unknown")"
          current = try await deps.store.transition(
            id: created.id, to: .failed, now: deps.clock.nowMilliseconds,
            effects: [.failure(.segmentOpenFailed, detail: detail)])
          recordTransition(.failed)
          publishTerminal(current, notice: MeetingErrorMessage.text(for: .segmentOpenFailed))
          return .refused(MeetingErrorMessage.text(for: .segmentOpenFailed))
        }
      }
      // Start sources into rings; a source that cannot start fails only its track.
      let captureStartedNs = deps.clock.monotonicNanoseconds
      var openSegments: [MeetingTransitionEffect] = []
      var runtimesToStart: [MeetingTrackKind: TrackRuntime] = [:]
      for kind in MeetingTrackKind.allCases {
        guard let source = sources[kind], let format = formats[kind], let handle = handles[kind]
        else { continue }
        do {
          let ring = try MeetingSampleRing(format: format)
          let encoder = try MeetingTrackEncoder(kind: kind, sourceFormat: format)
          _ = try await source.start(into: ring)
          let segment = MeetingSegment(
            id: UUID(), trackID: trackIDs[kind]!, sequence: 1, relativePath: handle.relativePath,
            startOffsetMs: 0, startedAt: deps.clock.nowMilliseconds,
            hostStartNs: Int64(clamping: deps.clock.monotonicNanoseconds), openReason: .start)
          let worker = try makeWorker(
            kind: kind, segment: segment, handle: handle, ring: ring, encoder: encoder)
          runtimesToStart[kind] = TrackRuntime(
            trackID: trackIDs[kind]!, source: source, ring: ring, worker: worker, segment: segment,
            format: format)
          sequences[kind] = 1
          trackOffsets[kind] = 0
          openSegments.append(.openSegment(segment))
        } catch {
          await source.stop()
          deps.writer.discard(handle)
          startFailures[kind] = (error as? MeetingSourceFailure ?? .unknown(code: -1)).reason(
            for: kind)
        }
      }
      let recordingAt = deps.clock.nowMilliseconds
      if runtimesToStart.isEmpty {
        current = try await deps.store.transition(
          id: created.id, to: .failed, now: recordingAt,
          effects: startFailures.map {
            .markTrackFailed(id: trackIDs[$0.key]!, reason: $0.value, at: recordingAt)
          }
            + [.failure(.bothSourcesFailed, detail: nil)])
        recordTransition(.failed)
        publishTerminal(current, notice: MeetingErrorMessage.text(for: .bothSourcesFailed))
        return .refused(MeetingErrorMessage.text(for: .bothSourcesFailed))
      }
      var effects: [MeetingTransitionEffect] = [.setStartedAt(recordingAt)] + openSegments
      for (kind, reason) in startFailures {
        effects.append(.markTrackFailed(id: trackIDs[kind]!, reason: reason, at: recordingAt))
      }
      current = try await deps.store.transition(
        id: created.id, to: .recording, now: recordingAt, effects: effects)
      recordTransition(.recording)
      meeting = current
      runtimes = runtimesToStart
      failedTracks = startFailures
      stretchStartedAt = recordingAt
      for runtime in runtimes.values { await runtime.worker.start() }
      await installAnalysisTaps()
      let editor = MeetingNotesEditor(
        meetingID: created.id, store: deps.store, clock: deps.clock)
      editor.intelligence = intelligence
      notesEditor = editor
      var published = MeetingStatus(
        id: created.id, state: .recording, storageWarning: warning, createdAt: created.createdAt)
      published.transcriptionRequested = deps.transcription != nil && options.transcription
      for kind in MeetingTrackKind.allCases {
        published[kind] =
          runtimes[kind] != nil
          ? .capturing : .failed(startFailures[kind] ?? .deviceLost, at: recordingAt)
      }
      if let (kind, reason) = startFailures.first {
        published.notice = MeetingErrorMessage.text(for: reason, track: kind)
      }
      status = published
      version += 1
      startTimers()
      let nowNs = deps.clock.monotonicNanoseconds
      deps.recorder?.record(
        phase: .meetingRecording, durationNanoseconds: nowNs &- startedAtNs,
        metric: .meetingStartDuration)
      deps.recorder?.record(
        phase: .meetingRecording, durationNanoseconds: nowNs &- captureStartedNs,
        metric: .meetingCaptureInitDuration)
      logger.notice("Meeting started; tracks=\(self.runtimes.count)")
      return .started(created.id)
    } catch MeetingStore.Error.alreadyActive(let id) {
      return .alreadyActive(id)
    } catch {
      logger.error("Meeting start failed: \(String(describing: error), privacy: .public)")
      await releaseAll()
      if let meeting, meeting.state.isActive {
        let failed = try? await deps.store.transition(
          id: meeting.id, to: .failed, now: deps.clock.nowMilliseconds,
          effects: [.failure(.storageUnavailable, detail: nil)])
        if let failed {
          publishTerminal(failed, notice: MeetingErrorMessage.text(for: .storageUnavailable))
        }
      }
      return refuse(MeetingErrorMessage.text(for: .storageUnavailable))
    }
  }

  private func refuse(_ text: String) -> StartOutcome {
    refusal = text
    return .refused(text)
  }

  // MARK: - Pause and resume

  func pause(reason: PauseReason) async {
    guard !busy, let meeting, status?.state == .recording else { return }
    busy = true
    defer { busy = false }
    let now = deps.clock.nowMilliseconds
    stopTimers()
    for runtime in runtimes.values { await runtime.source.stop() }
    let closeReason: SegmentCloseReason = reason == .systemSleep ? .systemSleep : .pause
    var effects = await finalizeRuntimes(closeReason: closeReason)
    let interval = PauseInterval(id: UUID(), meetingID: meeting.id, startedAt: now, reason: reason)
    effects.append(.openPause(interval))
    do {
      let updated = try await deps.store.transition(
        id: meeting.id, to: .paused, now: now, effects: effects)
      recordTransition(.paused)
      deps.transcription?.meetingDidPause(id: meeting.id)
      self.meeting = updated
      recordedBase += max(0, now - stretchStartedAt)
      runtimes = [:]
      var published = status!
      published.state = .paused
      published.pauseReason = reason
      elapsed.recorded = .milliseconds(recordedBase)
      for kind in MeetingTrackKind.allCases where published[kind] == .capturing {
        published[kind] = .finalized
      }
      published.notice = reason == .systemSleep ? MeetingErrorMessage.pausedForSleep : nil
      status = published
      version += 1
      deps.recorder?.record(phase: .meetingPaused, metric: .meetingPauseCount, itemCount: 1)
      startRSSSampler()
    } catch {
      logger.error("Pause failed: \(String(describing: error), privacy: .public)")
      await endInterrupted(reason: .storageWriteFailed, from: .paused)
    }
  }

  func resume() async {
    guard !busy, let meeting, status?.state == .paused else { return }
    busy = true
    defer { busy = false }
    let now = deps.clock.nowMilliseconds
    var effects: [MeetingTransitionEffect] = [.closeOpenPause(at: now, closedBy: .resume)]
    var started: [MeetingTrackKind: TrackRuntime] = [:]
    var failures: [MeetingTrackKind: MeetingFailureReason] = [:]
    for kind in MeetingTrackKind.allCases where failedTracks[kind] == nil {
      let sequence = (sequences[kind] ?? 0) + 1
      let handle: SegmentHandle
      do {
        handle = try deps.writer.open(meetingID: meeting.id, kind: kind, sequence: sequence)
      } catch {
        for runtime in started.values {
          await runtime.source.stop()
          deps.writer.discard(runtime.worker.handle)
        }
        await endInterrupted(reason: .storageUnavailable, from: .paused)
        return
      }
      let source = deps.sourceFactory(kind)
      do {
        let format = try await source.probeFormat()
        let ring = try MeetingSampleRing(format: format)
        let encoder = try MeetingTrackEncoder(kind: kind, sourceFormat: format)
        _ = try await source.start(into: ring)
        let segment = MeetingSegment(
          id: UUID(), trackID: trackIDs[kind]!, sequence: sequence,
          relativePath: handle.relativePath,
          startOffsetMs: trackOffsets[kind] ?? 0, startedAt: deps.clock.nowMilliseconds,
          hostStartNs: Int64(clamping: deps.clock.monotonicNanoseconds), openReason: .resume)
        let worker = try makeWorker(
          kind: kind, segment: segment, handle: handle, ring: ring, encoder: encoder)
        started[kind] = TrackRuntime(
          trackID: trackIDs[kind]!, source: source, ring: ring, worker: worker, segment: segment,
          format: format)
        sequences[kind] = sequence
        effects.append(.openSegment(segment))
      } catch {
        await source.stop()
        deps.writer.discard(handle)
        let reason = (error as? MeetingSourceFailure ?? .unknown(code: -1)).reason(for: kind)
        failures[kind] = reason
        effects.append(.markTrackFailed(id: trackIDs[kind]!, reason: reason, at: now))
      }
    }
    guard !started.isEmpty else {
      for (kind, reason) in failures { failedTracks[kind] = reason }
      await endInterrupted(reason: .bothSourcesFailed, from: .paused, trackFailures: failures)
      return
    }
    do {
      let updated = try await deps.store.transition(
        id: meeting.id, to: .recording, now: now, effects: effects)
      recordTransition(.recording)
      self.meeting = updated
      runtimes = started
      for (kind, reason) in failures { failedTracks[kind] = reason }
      stretchStartedAt = now
      for runtime in runtimes.values { await runtime.worker.start() }
      await installAnalysisTaps()
      var published = status!
      published.state = .recording
      published.pauseReason = nil
      published.notice = nil
      for kind in MeetingTrackKind.allCases {
        if runtimes[kind] != nil {
          published[kind] = .capturing
        } else if let reason = failedTracks[kind] {
          if case .failed = published[kind] {} else { published[kind] = .failed(reason, at: now) }
          published.notice = MeetingErrorMessage.text(for: reason, track: kind)
        }
      }
      status = published
      version += 1
      deps.recorder?.record(phase: .meetingRecording, metric: .meetingResumeCount, itemCount: 1)
      startTimers()
    } catch {
      logger.error("Resume failed: \(String(describing: error), privacy: .public)")
      for runtime in started.values { await runtime.source.stop() }
      runtimes = started
      await endInterrupted(reason: .storageWriteFailed, from: .paused)
    }
  }

  // MARK: - Stop

  func stop() async {
    guard !busy, let meeting, let state = status?.state, state == .recording || state == .paused
    else { return }
    busy = true
    defer { busy = false }
    await notesEditor?.flush()
    let now = deps.clock.nowMilliseconds
    let finalizeStartedNs = deps.clock.monotonicNanoseconds
    stopTimers()
    if state == .recording { recordedBase += max(0, now - stretchStartedAt) }
    var effects: [MeetingTransitionEffect] = [.setStoppedAt(now)]
    if state == .paused { effects.append(.closeOpenPause(at: now, closedBy: .stop)) }
    do {
      let finalizing = try await deps.store.transition(
        id: meeting.id, to: .finalizing, now: now, effects: effects)
      recordTransition(.finalizing)
      deps.transcription?.meetingDidStop(id: meeting.id)
      self.meeting = finalizing
      var published = status!
      published.state = .finalizing
      published.pauseReason = nil
      elapsed.recorded = .milliseconds(recordedBase)
      status = published
      version += 1
      startRSSSampler()
      for runtime in runtimes.values { await runtime.source.stop() }
      var failure: MeetingFailureReason?
      var failedKinds: [MeetingTrackKind: MeetingFailureReason] = [:]
      for (index, kind) in MeetingTrackKind.allCases.enumerated() {
        if index > 0, deps.options.debugSlowFinalize, MeetingRuntimeOptions.slowFinalizeSupported {
          try? await deps.clock.sleep(for: .seconds(10))
        }
        if let runtime = runtimes[kind] {
          let outcome = await finalizeRuntime(runtime, closeReason: .stop)
          for effect in outcome.effects {
            try await apply(effect, meetingID: meeting.id)
          }
          if let reason = outcome.failure {
            failure = failure ?? reason
            failedKinds[kind] = reason
          }
        }
        try await deps.store.setFinalizationStage(
          meetingID: meeting.id, stage: kind == .microphone ? .mic : .both,
          now: deps.clock.nowMilliseconds)
      }
      runtimes = [:]
      let completedAt = deps.clock.nowMilliseconds
      var final: [MeetingTransitionEffect] = [
        .setCompletedAt(completedAt), .finalizationStage(.both), .computeDurationWarnings,
      ]
      for kind in MeetingTrackKind.allCases {
        if let reason = failedKinds[kind] {
          final.append(.markTrackFailed(id: trackIDs[kind]!, reason: reason, at: completedAt))
        } else if failedTracks[kind] == nil {
          final.append(.markTrackFinalized(id: trackIDs[kind]!))
        }
      }
      let terminal: MeetingState
      if let failure {
        final.append(.failure(failure, detail: nil))
        terminal = .interrupted
      } else {
        terminal = .completed
      }
      let done = try await deps.store.transition(
        id: meeting.id, to: terminal, now: completedAt, effects: final)
      recordTransition(terminal)
      deps.recorder?.record(
        phase: .meetingFinalizing,
        durationNanoseconds: deps.clock.monotonicNanoseconds &- finalizeStartedNs,
        metric: .meetingFinalizationDuration)
      for (kind, reason) in failedKinds { failedTracks[kind] = reason }
      publishTerminal(done, notice: failure.map { MeetingErrorMessage.text(for: $0) })
      logger.notice("Meeting stopped: \(terminal.rawValue, privacy: .public)")
    } catch {
      logger.error("Stop failed: \(String(describing: error), privacy: .public)")
      await endInterrupted(reason: .storageWriteFailed, from: .finalizing)
    }
  }

  // MARK: - Failure paths

  /// Storage failure, both sources failed, or a failed write during pause/resume:
  /// stop capture, keep what was written, persist `interrupted` with `reason`.
  private func endInterrupted(
    reason: MeetingFailureReason, from: MeetingState,
    trackFailures: [MeetingTrackKind: MeetingFailureReason] = [:]
  ) async {
    guard let meeting else { return }
    stopTimers()
    let now = deps.clock.nowMilliseconds
    if status?.state == .recording { recordedBase += max(0, now - stretchStartedAt) }
    for runtime in runtimes.values { await runtime.source.stop() }
    var effects: [MeetingTransitionEffect] = []
    var current = (try? await deps.store.meeting(id: meeting.id)) ?? meeting
    if current.state == .recording || current.state == .paused {
      effects.append(.setStoppedAt(now))
      if current.state == .paused { effects.append(.closeOpenPause(at: now, closedBy: .stop)) }
      if let updated = try? await deps.store.transition(
        id: meeting.id, to: .finalizing, now: now, effects: effects)
      {
        current = updated
        recordTransition(.finalizing)
        deps.transcription?.meetingDidStop(id: meeting.id)
      }
    }
    var failedKinds = trackFailures
    let closeReason: SegmentCloseReason =
      reason == .storageWriteFailed || reason == .storageUnavailable
      ? .storageFailed : .sourceFailed
    for (kind, runtime) in runtimes {
      let outcome = await finalizeRuntime(runtime, closeReason: closeReason)
      for effect in outcome.effects { try? await apply(effect, meetingID: meeting.id) }
      if let trackReason = outcome.failure { failedKinds[kind] = trackReason }
    }
    runtimes = [:]
    let completedAt = deps.clock.nowMilliseconds
    var final: [MeetingTransitionEffect] = [
      .setCompletedAt(completedAt), .failure(reason, detail: nil), .computeDurationWarnings,
    ]
    for kind in MeetingTrackKind.allCases {
      if let trackReason = failedKinds[kind] {
        final.append(.markTrackFailed(id: trackIDs[kind]!, reason: trackReason, at: completedAt))
      } else if failedTracks[kind] == nil {
        final.append(.markTrackFinalized(id: trackIDs[kind]!))
      }
    }
    for (kind, trackReason) in failedKinds { failedTracks[kind] = trackReason }
    if current.state.isActive,
      let done = try? await deps.store.transition(
        id: meeting.id, to: .interrupted, now: completedAt, effects: final)
    {
      recordTransition(.interrupted)
      publishTerminal(done, notice: MeetingErrorMessage.text(for: reason))
    } else {
      publishTerminal(current, notice: MeetingErrorMessage.text(for: reason))
    }
    logger.error("Meeting interrupted: \(reason.rawValue, privacy: .public)")
  }

  /// One source failed: mark the track, finalize its segment, continue on the other.
  private func handleSourceFailure(kind: MeetingTrackKind, reason: MeetingFailureReason) async {
    guard let meeting, let runtime = runtimes[kind] else { return }
    await runtime.source.stop()
    let outcome = await finalizeRuntime(runtime, closeReason: .sourceFailed)
    runtimes[kind] = nil
    for effect in outcome.effects { try? await apply(effect, meetingID: meeting.id) }
    await recordSourceFailure(kind: kind, trackID: runtime.trackID, reason: reason)
  }

  /// The segment has already been finalized and its runtime removed. This also
  /// handles a replacement source failing before its new segment is opened.
  private func recordSourceFailure(
    kind: MeetingTrackKind, trackID: UUID, reason: MeetingFailureReason
  ) async {
    guard let meeting else { return }
    let now = deps.clock.nowMilliseconds
    failedTracks[kind] = reason
    try? await apply(
      .markTrackFailed(id: trackID, reason: reason, at: now), meetingID: meeting.id)
    if runtimes.isEmpty {
      await endInterrupted(reason: .bothSourcesFailed, from: .recording)
      return
    }
    var published = status!
    published[kind] = .failed(reason, at: now)
    published.notice = MeetingErrorMessage.text(for: reason, track: kind)
    status = published
    version += 1
    logger.error(
      "Source failed: \(kind.rawValue, privacy: .public) \(reason.rawValue, privacy: .public)")
  }

  /// The source restarted on a new device: close the segment, open the next.
  private func rollSegment(kind: MeetingTrackKind) async {
    guard let meeting, let runtime = runtimes[kind] else { return }
    await runtime.source.stop()
    let outcome = await finalizeRuntime(runtime, closeReason: .deviceChanged)
    for effect in outcome.effects { try? await apply(effect, meetingID: meeting.id) }
    if let reason = outcome.failure {
      runtimes[kind] = nil
      await handleTrackStorageFailure(kind: kind, reason: reason)
      return
    }
    let sequence = (sequences[kind] ?? 1) + 1
    var openedHandle: SegmentHandle?
    var openedRing: MeetingSampleRing?
    do {
      let handle = try deps.writer.open(meetingID: meeting.id, kind: kind, sequence: sequence)
      openedHandle = handle
      let format = try await runtime.source.probeFormat()
      let ring = try MeetingSampleRing(format: format)
      openedRing = ring
      let encoder = try MeetingTrackEncoder(kind: kind, sourceFormat: format)
      _ = try await runtime.source.start(into: ring)
      let segment = MeetingSegment(
        id: UUID(), trackID: runtime.trackID, sequence: sequence, relativePath: handle.relativePath,
        startOffsetMs: trackOffsets[kind] ?? 0, startedAt: deps.clock.nowMilliseconds,
        hostStartNs: Int64(clamping: deps.clock.monotonicNanoseconds), openReason: .deviceChanged)
      let worker = try makeWorker(
        kind: kind, segment: segment, handle: handle, ring: ring, encoder: encoder)
      _ = try await deps.store.openSegment(segment, now: deps.clock.nowMilliseconds)
      runtimes[kind] = TrackRuntime(
        trackID: runtime.trackID, source: runtime.source, ring: ring,
        worker: worker, segment: segment, format: format)
      sequences[kind] = sequence
      await worker.start()
      await installAnalysisTaps()
      version += 1
    } catch {
      await runtime.source.stop()
      openedRing?.closeAndJoin()
      if let handle = openedHandle { deps.writer.discard(handle) }
      runtimes[kind] = nil
      if let sourceFailure = error as? MeetingSourceFailure {
        await recordSourceFailure(
          kind: kind, trackID: runtime.trackID, reason: sourceFailure.reason(for: kind))
      } else {
        await handleTrackStorageFailure(kind: kind, reason: .storageUnavailable)
      }
    }
  }

  private func handleTrackStorageFailure(kind: MeetingTrackKind, reason: MeetingFailureReason) async
  {
    await endInterrupted(reason: reason, from: .recording, trackFailures: [kind: reason])
  }

  // MARK: - Finalization helpers

  private struct FinalizeOutcome {
    var effects: [MeetingTransitionEffect] = []
    var failure: MeetingFailureReason?
  }

  private func finalizeRuntimes(closeReason: SegmentCloseReason) async -> [MeetingTransitionEffect]
  {
    var effects: [MeetingTransitionEffect] = []
    for kind in MeetingTrackKind.allCases {
      guard let runtime = runtimes[kind] else { continue }
      let outcome = await finalizeRuntime(runtime, closeReason: closeReason)
      effects.append(contentsOf: outcome.effects)
      if let reason = outcome.failure {
        failedTracks[kind] = reason
        effects.append(
          .markTrackFailed(id: runtime.trackID, reason: reason, at: deps.clock.nowMilliseconds))
      }
    }
    return effects
  }

  /// Finalizes one worker. After a write failure the `.part` file is renamed only
  /// when it still holds complete frames; otherwise it is kept as unrecoverable.
  private func finalizeRuntime(_ runtime: TrackRuntime, closeReason: SegmentCloseReason) async
    -> FinalizeOutcome
  {
    refreshDroppedFrames()
    var outcome = FinalizeOutcome()
    let handle = runtime.worker.handle
    switch await runtime.worker.finalize() {
    case .success(let completion):
      outcome.effects.append(
        .finalizeSegment(
          id: runtime.segment.id, durationMs: completion.durationMs, byteSize: completion.byteSize,
          relativePath: handle.finalRelativePath, closeReason: closeReason,
          droppedFrames: completion.droppedFrames))
      trackOffsets[runtime.worker.kind, default: 0] += completion.durationMs
    case .failure(let failure):
      outcome.failure = failure.reason
      if let part = deps.storageRoot.resolve(relativePath: handle.relativePath),
        let final = deps.storageRoot.resolve(relativePath: handle.finalRelativePath),
        let scan = try? ADTSValidator.scan(url: part), scan.completeFrames > 0,
        (try? FileSegmentWriter.truncateAndRename(part, to: final, length: scan.completeBytes))
          != nil
      {
        outcome.effects.append(
          .finalizeSegment(
            id: runtime.segment.id, durationMs: scan.durationMs,
            byteSize: Int64(scan.completeBytes),
            relativePath: handle.finalRelativePath, closeReason: .storageFailed,
            droppedFrames: runtime.ring.droppedFrames))
        trackOffsets[runtime.worker.kind, default: 0] += scan.durationMs
      } else {
        outcome.effects.append(
          .markSegmentUnrecoverable(
            id: runtime.segment.id, reason: failure.reason,
            note: "code=\(runtime.worker.latch.errorCode)"))
      }
    }
    runtime.ring.closeAndJoin()
    refreshDroppedFrames()
    return outcome
  }

  private func apply(_ effect: MeetingTransitionEffect, meetingID: UUID) async throws {
    let now = deps.clock.nowMilliseconds
    switch effect {
    case .finalizeSegment(
      let id, let durationMs, let byteSize, let path, let closeReason, let dropped):
      try await deps.store.finalizeSegment(
        id: id, durationMs: durationMs, byteSize: byteSize, relativePath: path,
        closeReason: closeReason,
        droppedFrames: dropped, now: now)
    case .markSegmentUnrecoverable(let id, let reason, let note):
      try await deps.store.markSegmentUnrecoverable(id: id, reason: reason, note: note, now: now)
    case .markTrackFailed(let id, let reason, let at):
      try await deps.store.markTrackFailed(id: id, reason: reason, at: at)
    case .markTrackFinalized(let id):
      try await deps.store.markTrackFinalized(id: id, now: now)
    default:
      break
    }
  }

  var transcriptionCoordinator: MeetingTranscriptionCoordinator? {
    deps.transcription as? MeetingTranscriptionCoordinator
  }

  func meetingWillDelete(id: UUID) async {
    await deps.transcription?.meetingWillDelete(id: id)
  }

  private func installAnalysisTaps() async {
    guard let id = meeting?.id, let observer = deps.transcription,
      let sequence = runtimes.values.map({ $0.segment.sequence }).max()
    else { return }
    // A device change can roll just one durable track. Until track sequences
    // align again, no shared analysis stretch can claim correct source timing.
    let aligned = Set(runtimes.values.map { $0.segment.sequence }).count == 1
    let formats = aligned ? runtimes.mapValues(\.format) : [:]
    let taps = observer.stretchDidStart(meetingID: id, sequence: sequence, tracks: formats)
    for (kind, runtime) in runtimes {
      await runtime.worker.setAnalysisSink(taps?[kind])
    }
  }

  private func makeWorker(
    kind: MeetingTrackKind, segment: MeetingSegment, handle: SegmentHandle, ring: MeetingSampleRing,
    encoder: MeetingTrackEncoder
  ) throws -> MeetingTrackWorker {
    let store = deps.store
    let clock = deps.clock
    return try MeetingTrackWorker(
      kind: kind, segmentID: segment.id, handle: handle, ring: ring, encoder: encoder,
      writer: deps.writer, clock: clock, recorder: deps.recorder
    ) { [weak self] beat in
      try? await store.progressSegment(
        id: beat.segmentID, durationMs: beat.durationMs, byteSize: beat.byteSize,
        droppedFrames: beat.droppedFrames, now: clock.nowMilliseconds)
      await self?.noteHeartbeat(beat)
    }
  }

  private func noteHeartbeat(_ beat: MeetingTrackWorker.Heartbeat) {
    guard status?.state == .recording else { return }
    refreshDroppedFrames()
  }

  /// Each active ring contributes only newly observed loss. The total survives
  /// runtime replacement and pause; storage stays bounded to the two tracks.
  private func refreshDroppedFrames() {
    for kind in MeetingTrackKind.allCases {
      guard var runtime = runtimes[kind] else { continue }
      let dropped = runtime.ring.droppedFrames
      cumulativeDroppedFrames += max(0, dropped - runtime.sampledDroppedFrames)
      runtime.sampledDroppedFrames = dropped
      runtimes[kind] = runtime
    }
    if status?.droppedFrames != cumulativeDroppedFrames {
      status?.droppedFrames = cumulativeDroppedFrames
    }
  }

  private func publishTerminal(_ meeting: Meeting, notice: String?) {
    stopTimers()
    self.meeting = meeting
    var published =
      status ?? MeetingStatus(id: meeting.id, state: meeting.state, createdAt: meeting.createdAt)
    published.state = meeting.state
    published.pauseReason = nil
    elapsed.recorded = .milliseconds(meeting.recordedMs)
    for kind in MeetingTrackKind.allCases {
      if let reason = failedTracks[kind] {
        if case .failed = published[kind] {
        } else {
          published[kind] = .failed(reason, at: meeting.completedAt ?? deps.clock.nowMilliseconds)
        }
      } else if published[kind] == .capturing {
        published[kind] = .finalized
      }
    }
    published.notice = notice ?? published.notice
    status = published
    version += 1
    runtimes = [:]
    if let observer = deps.transcription {
      let store = deps.store
      Task {
        if let detail = try? await store.detail(id: meeting.id) {
          observer.meetingDidComplete(id: meeting.id, detail: detail)
        }
      }
    }
  }

  private func releaseAll() async {
    stopTimers()
    for runtime in runtimes.values {
      await runtime.source.stop()
      _ = await runtime.worker.finalize()
      deps.writer.abandon(runtime.worker.handle)
    }
    runtimes = [:]
  }

  // MARK: - Timers

  private func startTimers() {
    stopTimers()
    let clock = deps.clock
    lastPermissionCheckMs = nil
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await clock.sleep(for: MeetingCoordinator.pollInterval) } catch { return }
        guard let self else { return }
        await self.poll()
      }
    }
    elapsedTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await clock.sleep(for: MeetingCoordinator.elapsedInterval) } catch { return }
        guard let self, self.status?.state == .recording else { continue }
        // `status` changes only when the dropped-frame count does.
        self.refreshDroppedFrames()
        self.elapsed.recorded = .milliseconds(
          self.recordedBase + max(0, clock.nowMilliseconds - self.stretchStartedAt))
      }
    }
    startRSSSampler()
  }

  private func startRSSSampler() {
    guard rssTask == nil, deps.recorder != nil else { return }
    let clock = deps.clock
    rssTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await clock.sleep(for: MeetingCoordinator.rssInterval) } catch { return }
        guard let self, let state = self.status?.state, state.isActive else { return }
        let phase: ResourceRecorder.Phase
        switch state {
        case .paused: phase = .meetingPaused
        case .finalizing: phase = .meetingFinalizing
        default: phase = .meetingRecording
        }
        self.deps.recorder?.record(phase: phase, rssBytes: ResourceRecorder.residentBytes())
      }
    }
  }

  private func stopTimers() {
    pollTask?.cancel()
    pollTask = nil
    elapsedTask?.cancel()
    elapsedTask = nil
    rssTask?.cancel()
    rssTask = nil
  }

  private func poll() async {
    guard !busy, status?.state == .recording else { return }
    refreshDroppedFrames()
    for (kind, runtime) in runtimes {
      if let reason = runtime.worker.storageFailure {
        await handleTrackStorageFailure(kind: kind, reason: reason)
        return
      }
    }
    let now = deps.clock.nowMilliseconds
    let checkPermissions =
      lastPermissionCheckMs.map { now - $0 >= Self.permissionIntervalMs } ?? true
    if checkPermissions { lastPermissionCheckMs = now }
    for (kind, runtime) in runtimes {
      if checkPermissions, let failure = await runtime.source.failure() {
        await handleSourceFailure(kind: kind, reason: failure.reason(for: kind))
        return
      }
      if checkPermissions, kind == .microphone,
        deps.permissions.microphoneStatus() != .authorized
      {
        await handleSourceFailure(kind: kind, reason: .permissionRevoked)
        return
      }
      if await runtime.source.consumeDeviceChange() {
        await rollSegment(kind: kind)
        return
      }
    }
  }

  private func recordTransition(_ state: MeetingState) {
    deps.recorder?.record(
      phase: .meetingRecording, metric: .meetingTransition, itemCount: 1, meetingKey: state.rawValue
    )
  }
}

/// The coordinator's recorded time. A separate observable so a per-second tick
/// invalidates only the views that read it, never whoever reads `status`.
@MainActor @Observable
final class MeetingElapsed {
  fileprivate(set) var recorded: Duration = .zero

  /// Recorded time as whole milliseconds, for the duration formatter.
  var milliseconds: Int64 {
    let components = recorded.components
    return Int64(components.seconds) * 1_000 + Int64(components.attoseconds / 1_000_000_000_000_000)
  }
}

/// One `willSleepNotification` observer, removed with its owner. The center is
/// injectable so tests can post the notification.
private final class SleepObserver {
  private let center: NotificationCenter
  private var token: NSObjectProtocol?
  @MainActor init(center: NotificationCenter, sleep: @escaping @MainActor @Sendable () -> Void) {
    self.center = center
    token = center.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { sleep() }
    }
  }
  deinit { if let token { center.removeObserver(token) } }
}

extension MeetingStatus {
  subscript(kind: MeetingTrackKind) -> TrackStatus {
    get { track(kind) }
    set {
      switch kind {
      case .microphone: microphone = newValue
      case .system: system = newValue
      }
    }
  }
}
