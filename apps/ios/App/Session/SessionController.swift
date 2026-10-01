import Foundation
import LocalFlowCore
import LocalFlowSpeech
import Observation
import UIKit
import os

/// The one listening session (data-model.md §3). It owns the engine while the session
/// lasts, one dictation at a time, and says every state change through `onChange`.
/// Logs carry IDs, states and durations only.
@MainActor
@Observable
final class SessionController {
  enum Origin: Sendable { case keyboard, app }

  struct PhoneSession: Equatable {
    let id: UUID
    var origin: Origin
    let startedAt: Date
    var idleDeadline: Date?
    var state: SessionFile.State
    var endReason: SessionFile.EndReason?
    /// Set in `recording`, cleared otherwise (017 data-model §2).
    var recordingStartedAt: Date?
    /// The input port name in `recording`, refreshed on route change.
    var inputName: String?
  }

  struct ActiveDictation {
    let id: UUID
    let requestID: UUID
    let source: PhoneDictationStore.Source
    let startedAt: Date
    let spool: AudioSpool
  }

  struct DictationResult: Equatable, Sendable {
    let requestID: UUID
    let dictationID: UUID
    let text: String
    let limitReached: Bool
  }

  enum StartOutcome: Equatable { case started, busy, noSession, failed }

  private(set) var session: PhoneSession?
  private(set) var lastRequestID: UUID?
  private(set) var lastOutcome: SessionFile.Outcome?
  private(set) var level: Float = 0
  @ObservationIgnored private(set) var current: ActiveDictation?
  /// Diagnostics: when the last dictation stopped and when its text was ready.
  private(set) var lastStopAt: Date?
  private(set) var lastResultAt: Date?
  private(set) var lastResultID: UUID?

  @ObservationIgnored var onChange: (() -> Void)?
  /// Keyboard dictations, for `result.json`.
  @ObservationIgnored var onResult: ((DictationResult) -> Void)?
  /// In-app notes, which never go to the keyboard.
  @ObservationIgnored var onNote: ((DictationResult) -> Void)?
  @ObservationIgnored var onLevel: ((Float) -> Void)?

  private let capture: AudioCapturing
  private let pipeline: PhoneDictationPipeline
  private let store: PhoneDictationStore
  private let keepReady: KeepReady
  private let spoolRoot: URL
  private let modelReady: () -> Bool
  private let idleTimeout: () -> IdleTimeout
  private let now: () -> Date
  private var engineRunning = false
  private static let log = Logger(subsystem: "org.localflow.LocalFlowPhone", category: "session")

  init(
    capture: AudioCapturing, pipeline: PhoneDictationPipeline, store: PhoneDictationStore,
    keepReady: KeepReady, spoolRoot: URL, modelReady: @escaping () -> Bool,
    idleTimeout: @escaping () -> IdleTimeout = { IdleTimeout.current() },
    now: @escaping () -> Date = Date.init
  ) {
    self.capture = capture
    self.pipeline = pipeline
    self.store = store
    self.keepReady = keepReady
    self.spoolRoot = spoolRoot
    self.modelReady = modelReady
    self.idleTimeout = idleTimeout
    self.now = now
    capture.onLevel = { [weak self] level in
      self?.level = level
      self?.onLevel?(level)
    }
    capture.onCaptureEnded = { [weak self] end in
      Task { await self?.finish(end) }
    }
    capture.onInterruption = { [weak self] in
      Task { await self?.interrupted() }
    }
    capture.onRouteChange = { [weak self] in self?.routeChanged() }
  }

  var isActive: Bool { session.map { $0.state != .ended } ?? false }

  // MARK: Session

  /// Opens a session, or keeps a live one. The keyboard's URL turns an in-app session
  /// into a keyboard session that follows the idle timeout.
  func open(origin: Origin) async {
    if var live = session, live.state != .ended {
      if origin == .keyboard, live.origin == .app {
        live.origin = .keyboard
        session = live
        changed()
      }
      return
    }
    session = PhoneSession(id: UUID(), origin: origin, startedAt: now(), state: .starting)
    changed()
    guard modelReady() else { return end(.modelUnavailable) }
    guard await capture.requestPermission() else { return end(.permissionDenied) }
    guard session?.state == .starting else { return }
    do {
      try capture.startEngine()
      engineRunning = true
    } catch {
      Self.log.error("Audio engine failed to start")
      return end(.audioFailure)
    }
    keepReady.hold(.session)
    setReady()
  }

  func end(_ reason: SessionFile.EndReason) {
    guard var live = session, live.state != .ended else { return }
    if let current {
      // Ending mid-dictation discards the audio; nothing is transcribed.
      _ = capture.endDictation()
      try? current.spool.cleanup()
      self.current = nil
    }
    if engineRunning {
      capture.stopEngine()
      engineRunning = false
    }
    keepReady.release(.session, unloadNow: true)
    live.state = .ended
    live.endReason = reason
    live.idleDeadline = nil
    live.recordingStartedAt = nil
    live.inputName = nil
    session = live
    Self.log.notice("Session ended: \(reason.rawValue, privacy: .public)")
    changed()
  }

  /// Every second: ends a `ready` session whose deadline has passed.
  func tick() {
    guard let session, session.state == .ready, let deadline = session.idleDeadline,
      now() >= deadline
    else { return }
    end(.idleTimeout)
  }

  func memoryWarning() {
    guard session?.state != .recording, session?.state != .finishing else { return }
    keepReady.dropAll()
  }

  // MARK: Dictation

  @discardableResult
  func start(requestID: UUID, source: PhoneDictationStore.Source = .keyboard) -> StartOutcome {
    guard var live = session, live.state != .ended else {
      report(requestID, .noSession)
      return .noSession
    }
    guard live.state == .ready else {
      report(requestID, .busy)
      return .busy
    }
    let id = UUID()
    do {
      let spool = try AudioSpool(
        rootDirectory: spoolRoot, sessionID: id, maximumBytes: PhoneServices.spoolBytes)
      try capture.beginDictation(spool: spool)
      current = ActiveDictation(
        id: id, requestID: requestID, source: source, startedAt: now(), spool: spool)
    } catch {
      Self.log.error("Dictation could not start")
      report(requestID, .failed)
      return .failed
    }
    live.state = .recording
    live.idleDeadline = nil
    live.recordingStartedAt = now()
    live.inputName = capture.inputName
    session = live
    changed()
    return .started
  }

  /// A stop that does not match the current dictation's request is ignored.
  func stop(requestID: UUID) async {
    guard current?.requestID == requestID, session?.state == .recording else { return }
    await finish(.stopped)
  }

  /// Drops the current dictation without transcribing it.
  func cancel(requestID: UUID) {
    guard let current, current.requestID == requestID, session?.state == .recording else { return }
    _ = capture.endDictation()
    try? current.spool.cleanup()
    self.current = nil
    setReady()
  }

  private func interrupted() async {
    if session?.state == .recording {
      let task = UIApplication.shared.beginBackgroundTask(withName: "Finish dictation")
      await finish(.interrupted)
      UIApplication.shared.endBackgroundTask(task)
    }
    end(.interrupted)
  }

  func finish(_ end: CaptureEnd) async {
    guard let dictation = current, var live = session, live.state == .recording else { return }
    live.state = .finishing
    live.recordingStartedAt = nil
    live.inputName = nil
    session = live
    lastStopAt = now()
    changed()
    let samples = capture.endDictation()
    let stopReason: TranscriptionEntry.StopReason =
      switch end {
      case .stopped: .keyRelease
      case .durationLimit: .durationLimit
      case .overflow: .overflow
      case .interrupted, .failed: .failure
      }
    do {
      let output = try await pipeline.run(
        spool: dictation.spool, sampleCount: samples, dictationID: dictation.id,
        stopReason: stopReason)
      if output.text.isEmpty {
        report(dictation.requestID, .empty, notify: false)
      } else {
        // History first; a failed write still delivers the text (FR-023).
        do {
          try await store.save(
            .init(
              id: dictation.id, text: output.text, createdAt: now(), source: dictation.source,
              durationMilliseconds: samples / 16, quality: output.quality,
              stopReason: output.stopReason,
              endDetail: end == .durationLimit
                ? .limitReached : end == .interrupted ? .interrupted : nil,
              sessionID: live.id, detail: output.detail))
        } catch {
          Self.log.error("history_write_failed")
        }
        let result = DictationResult(
          requestID: dictation.requestID, dictationID: dictation.id, text: output.text,
          limitReached: end == .durationLimit)
        lastResultAt = now()
        lastResultID = dictation.id
        if dictation.source == .app { onNote?(result) } else { onResult?(result) }
      }
    } catch {
      Self.log.error("Dictation failed")
      report(dictation.requestID, .failed, notify: false)
    }
    current = nil
    guard session?.state == .finishing else { return }
    if session?.origin == .app || idleTimeout() == .afterOne || end == .interrupted {
      self.end(end == .interrupted ? .interrupted : .afterOneDictation)
    } else {
      setReady()
    }
  }

  // MARK: Helpers

  private func setReady() {
    guard var live = session else { return }
    live.state = .ready
    // `never` stores no deadline, so `tick()` never ends the session.
    live.idleDeadline = idleTimeout().seconds.map { now().addingTimeInterval($0) }
    live.recordingStartedAt = nil
    live.inputName = nil
    session = live
    changed()
  }

  private func routeChanged() {
    guard var live = session, live.state == .recording else { return }
    let name = capture.inputName
    guard name != live.inputName else { return }
    live.inputName = name
    session = live
    changed()
  }

  private func report(_ requestID: UUID, _ outcome: SessionFile.Outcome, notify: Bool = true) {
    lastRequestID = requestID
    lastOutcome = outcome
    if notify { changed() }
  }

  private func changed() { onChange?() }

  /// `session.json` for the keyboard.
  func sessionFile() -> SessionFile? {
    guard let session else { return nil }
    return SessionFile(
      sessionID: session.id, state: session.state,
      idleDeadline: session.idleDeadline.map(Handoff.milliseconds),
      idleTimeout: idleTimeout().rawValue, dictationID: current?.id,
      endReason: session.endReason, lastRequestID: lastRequestID, lastOutcome: lastOutcome,
      updatedAt: Handoff.milliseconds(now()),
      recordingStartedAt: session.recordingStartedAt.map(Handoff.milliseconds),
      inputName: session.inputName,
      dictationSource: current.flatMap { SessionFile.Source(rawValue: $0.source.rawValue) })
  }
}
