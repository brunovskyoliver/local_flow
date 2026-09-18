import AppKit
import Foundation
import OSLog
import Observation

/// Content-free processing measurements for one session. Every field is a
/// duration, a byte size or a count of an already-bounded collection; nothing
/// here identifies speech, vocabulary entries, targets or files.
struct ProcessingMetrics: Sendable, Codable, Equatable {
  let sessionID: UUID
  let inputSamples: Int
  let windowCount: Int
  let recognitionNanoseconds: UInt64?
  let assemblyNanoseconds: UInt64?
  let normalizationNanoseconds: UInt64?
  let persistenceNanoseconds: UInt64?
  /// From admission to the terminal transition, including insertion and cleanup.
  let endToEndNanoseconds: UInt64
  let rawTextBytes: Int
  let assembledTextBytes: Int
  let normalizedTextBytes: Int
  /// Serialized quality-detail bytes; zero when the session produced no detail.
  let metadataBytes: Int
  let completionReasonCount: Int
  let appliedRuleCount: Int
  let appliedEntryCount: Int
  let incomplete: Bool

  init(
    sessionID: UUID, inputSamples: Int, result: TranscriptionResult,
    persistenceNanoseconds: UInt64?, endToEndNanoseconds: UInt64
  ) {
    func nanoseconds(_ seconds: Double?) -> UInt64? {
      guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
      return UInt64(min(seconds, 1e9) * 1_000_000_000)
    }
    let detail = result.detail
    self.sessionID = sessionID
    self.inputSamples = inputSamples
    windowCount = result.rawWindows.count
    recognitionNanoseconds = nanoseconds(detail?.provenance.stageDurations["recognition"])
    assemblyNanoseconds = nanoseconds(detail?.provenance.stageDurations["assembly"])
    normalizationNanoseconds = nanoseconds(detail?.provenance.stageDurations["normalization"])
    self.persistenceNanoseconds = persistenceNanoseconds
    self.endToEndNanoseconds = endToEndNanoseconds
    rawTextBytes = result.rawWindows.reduce(0) { $0 + $1.text.utf8.count }
    assembledTextBytes = detail?.assembledText.utf8.count ?? 0
    normalizedTextBytes = result.text.utf8.count
    metadataBytes = detail.map { $0.payloadBytes == Int.max ? 0 : $0.payloadBytes } ?? 0
    completionReasonCount = result.completionReasons.count
    appliedRuleCount = detail?.appliedRuleIDs.count ?? 0
    appliedEntryCount = detail?.appliedEntryIDs.count ?? 0
    incomplete = result.incomplete
  }
}

/// Serial presentation/session decisions; IO and inference belong to injected services.
@MainActor @Observable
final class DictationCoordinator {
  private(set) var state: DictationSession.State = .idle
  private(set) var status = "Install a verified speech model to begin."
  private(set) var level: Float = 0
  private(set) var targetDisplayPoint: NSPoint?
  private(set) var history: [TranscriptionEntry] = []
  @ObservationIgnored private var previewEnabled = false
  private(set) var unsavedEnvelope: TranscriptionEnvelope?
  var unsaved: TranscriptionEntry? { unsavedEnvelope?.entry }
  private(set) var busy = false
  private(set) var storageBlocked = false
  private(set) var capacityBlocked = false
  private(set) var hasRecovery = false
  @ObservationIgnored private var pendingOutcome:
    (UUID, Int64, UUID, TranscriptionStore.Outcome, RewriteDelivery)?
  var successfulDictation: ((TranscriptionEntry) -> Void)?
  var historyChanged: (() -> Void)?
  var sessionStarted: ((UUID) -> Void)?
  /// Fires once automatic insertion is confirmed, with the inserted text and its target.
  var insertionConfirmed: ((String, CapturedTarget) -> Void)?
  @ObservationIgnored private var explicitCancellation: (() -> Void)?
  var stateChanged: ((DictationSession.State) -> Void)?
  /// Fires once per session that reached recognition, after its terminal transition.
  var processingMeasured: ((ProcessingMetrics) -> Void)?
  @ObservationIgnored private(set) var lastProcessingMetrics: ProcessingMetrics?
  /// Bounded notice shown after a rewrite fell back, was refused or was cancelled.
  private(set) var rewriteNotice: RewriteActionNotice?
  var rewriteNoticeChanged: ((RewriteActionNotice?) -> Void)?
  /// Retry from the notice; wired by the app to the history retry flow.
  var rewriteRetryRequested: ((UUID) -> Void)?
  /// Feature 004 exclusivity: returns a refusal text while a meeting is active.
  /// Nil (the default) leaves the dictation path exactly as before.
  var admissionGuard: (@MainActor () -> String?)?
  /// Fires with the guard's text when `begin()` was refused by it.
  var admissionRefused: ((String) -> Void)?
  @ObservationIgnored private var pendingRewriteAttemptID: UUID?
  @ObservationIgnored private var bypassRewriteRequested = false

  @ObservationIgnored private let store: any TranscriptionStoring
  @ObservationIgnored private let vocabulary: any VocabularyProviding
  @ObservationIgnored private let lifecycle: ModelLifecycleCoordinator
  @ObservationIgnored private let transcriber: any DictationTranscribing
  @ObservationIgnored private let capture: any AudioCapturing
  @ObservationIgnored private let insertion: any TextInserting
  @ObservationIgnored private let rewriter: (any RewriteRequesting)?
  @ObservationIgnored private let spoolRoot: URL
  @ObservationIgnored private var operation: Task<Void, Never>?
  @ObservationIgnored private var controlConsumer: Task<Void, Never>?
  @ObservationIgnored private let mailbox: ControlMailbox
  @ObservationIgnored private(set) var controlTag: ControlMailbox.Tag?
  @ObservationIgnored private var controlGeneration: UInt64 = 0
  @ObservationIgnored private var controlOverflow = false
  @ObservationIgnored private var requestedStop: ControlMailbox.StopReason?
  @ObservationIgnored private var stopRequested = false
  @ObservationIgnored private var recordingStarted = false
  @ObservationIgnored private var cancelled = false
  @ObservationIgnored private var cleanupBlocked = false
  @ObservationIgnored private var unsavedReservation: TranscriptionStore.Reservation?

  init(
    store: any TranscriptionStoring, lifecycle: ModelLifecycleCoordinator,
    capture: any AudioCapturing, insertion: any TextInserting, spoolRoot: URL,
    mailbox: ControlMailbox = ControlMailbox(),
    transcriber: (any DictationTranscribing)? = nil,
    vocabulary: (any VocabularyProviding)? = nil,
    rewriter: (any RewriteRequesting)? = nil
  ) {
    self.store = store
    self.rewriter = rewriter
    self.vocabulary = vocabulary ?? EmptyVocabularyProvider()
    self.lifecycle = lifecycle
    self.transcriber = transcriber ?? WindowedTranscriber(lifecycle: lifecycle)
    self.capture = capture
    self.insertion = insertion
    self.spoolRoot = spoolRoot
    self.mailbox = mailbox
  }

  /// Local measurement reads bounded control-queue counts, never events.
  var controlQueueDepth: ControlMailbox.Depth { mailbox.depthSnapshot() }
  func captureQueueOccupancy() async -> QueueOccupancy? { await capture.queueOccupancy() }

  var canBegin: Bool {
    (!busy || state == .rewriting) && unsaved == nil && !cleanupBlocked && !storageBlocked
      && !capacityBlocked
  }

  func begin(mode: RewriteMode? = nil) {
    guard canBegin else { return }
    if let reason = admissionGuard?() {
      admissionRefused?(reason)
      return
    }
    // The previous rewrite keeps running under its own attempt identity.
    // Its dictation task may finish only into history once this tag changes.
    controlConsumer?.cancel()
    pendingRewriteAttemptID = nil
    bypassRewriteRequested = false
    busy = true
    stopRequested = false
    recordingStarted = false
    cancelled = false
    controlOverflow = false
    requestedStop = nil
    controlGeneration &+= 1
    let tag = ControlMailbox.Tag(sessionID: UUID(), generation: controlGeneration)
    controlTag = tag
    setRewriteNotice(nil)
    sessionStarted?(tag.sessionID)
    mailbox.begin(tag)
    mailbox.tryEnqueue(.init(tag: tag, value: .begin))
    // One consumer for the admitted session, including suspended preparation and
    // inference. Event callbacks never create tasks or wait for IO.
    controlConsumer = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, self.busy, self.controlTag == tag else { return }
        self.consumeControls()
        try? await ContinuousClock().sleep(for: .milliseconds(34))
      }
    }
    operation = Task { await run(tag: tag, mode: mode) }
  }
  func release(bypassRewrite: Bool = false) {
    guard busy, let tag = controlTag else { return }
    if bypassRewrite { bypassRewriteRequested = true }
    mailbox.requestStop(.keyRelease, for: tag)
  }
  func cancel() {
    if let explicitCancellation {
      explicitCancellation()
      return
    }
    // During rewriting, Escape and the indicator button cancel the rewrite only;
    // the saved transcript is then inserted as usual.
    if state == .rewriting, let pendingRewriteAttemptID {
      rewriter?.cancel(attemptID: pendingRewriteAttemptID)
      return
    }
    guard busy, let tag = controlTag else { return }
    mailbox.requestCancel(for: tag)
  }

  func retryRewrite() {
    guard let notice = rewriteNotice else { return }
    setRewriteNotice(nil)
    rewriteRetryRequested?(notice.dictationID)
  }

  func dismissRewriteNotice() { setRewriteNotice(nil) }

  private func setRewriteNotice(_ notice: RewriteActionNotice?) {
    rewriteNotice = notice
    rewriteNoticeChanged?(notice)
  }

  private func consumeControls() {
    guard let tag = controlTag else { return }
    // This is the sole queue consumer; stale tags can never affect this session.
    for _ in 0..<ControlMailbox.capacity {
      guard let event = mailbox.dequeue() else { break }
      guard event.tag == tag else { continue }
      if case .stop(let reason) = event.value { mailbox.requestStop(reason, for: tag) }
    }
    if state == .rewriting, let pendingRewriteAttemptID,
      mailbox.takeRewriteCancellation(for: tag)
    {
      rewriter?.cancel(attemptID: pendingRewriteAttemptID)
      return
    }
    let flags = mailbox.consumeFlags(for: tag)
    if let reason = flags.stop {
      stopRequested = true
      requestedStop = reason
    }
    controlOverflow = controlOverflow || flags.overflowed
    if flags.cancel || controlOverflow || requestedStop == .cancel, !cancelled {
      cancelled = true
      stopRequested = true
      transition(.cancelling)
      operation?.cancel()
    }
    if let snapshot = mailbox.takePresentation(), snapshot.tag == tag,
      case .audioLevel(let value) = snapshot.value
    {
      level = value.isFinite ? min(1, max(0, value)) : 0
    }
  }
  private var allowsAutomaticInsertion: Bool {
    !cancelled && !controlOverflow && (requestedStop == nil || requestedStop == .keyRelease)
  }

  private func transition(_ value: DictationSession.State) {
    state = value
    stateChanged?(value)
  }

  private func run(tag: ControlMailbox.Tag, mode: RewriteMode?) async {
    var session = DictationSession(id: tag.sessionID)
    let admitted = DispatchTime.now().uptimeNanoseconds
    var recognized: (result: TranscriptionResult, samples: Int)?
    var persistenceNanoseconds: UInt64?
    defer {
      if let recognized {
        let metrics = ProcessingMetrics(
          sessionID: session.id, inputSamples: recognized.samples, result: recognized.result,
          persistenceNanoseconds: persistenceNanoseconds,
          endToEndNanoseconds: DispatchTime.now().uptimeNanoseconds &- admitted)
        lastProcessingMetrics = metrics
        processingMeasured?(metrics)
      }
    }
    defer {
      if controlTag == tag {
        consumeControls()
        mailbox.requestTerminal(
          controlOverflow || state == .failed ? .failed : (cancelled ? .cancelled : .completed),
          for: tag)
        controlConsumer?.cancel()
        controlConsumer = nil
        if controlOverflow {
          status =
            "Dictation stopped because control delivery overflowed. Any saved text needs review."
          transition(.failed)
        }
        busy = false
        operation = nil
        level = 0
      }
    }
    var failureStage = "checking storage"
    do {
      consumeControls()
      session.target = await insertion.captureTarget()
      consumeControls()
      targetDisplayPoint = IndicatorPanel.displayPoint(for: session.target)
      session.reservation = try await store.reserve()
      consumeControls()
      try Task.checkCancellation()
      guard !stopRequested else { throw DictationFailure.cancelled }
      failureStage = "loading preferred spellings"
      session.vocabulary = try await vocabulary.snapshot()
      consumeControls()
      guard !stopRequested else { throw DictationFailure.cancelled }
      transition(.preparing)
      status = "Preparing speech model…"
      failureStage = "requesting microphone access"
      guard await capture.authorize() else { throw AudioCaptureFailure.permissionDenied }
      consumeControls()
      guard !stopRequested, !Task.isCancelled else { throw DictationFailure.cancelled }
      failureStage = "loading the speech model"
      session.lease = try await lifecycle.acquire(session: session.id)
      consumeControls()
      guard !stopRequested, !Task.isCancelled else { throw DictationFailure.cancelled }
      let root = spoolRoot
      let id = session.id
      failureStage = "creating temporary audio storage"
      session.audio = try await Task.detached { try AudioSpool(rootDirectory: root, sessionID: id) }
        .value
      consumeControls()
      guard !stopRequested, !Task.isCancelled else { throw DictationFailure.cancelled }
      failureStage = "starting the microphone"
      try await capture.start(sessionID: session.id, spool: session.audio!)
      consumeControls()
      session.startedAt = .now
      session.deadline = session.startedAt?.advanced(by: .seconds(180))
      if !stopRequested {
        recordingStarted = true
        transition(.recording)
        status = "Recording"
      }
      while !stopRequested, !Task.isCancelled {
        if let snapshot = await capture.snapshot(), snapshot.sessionID == session.id {
          mailbox.publishPresentation(.init(tag: tag, value: .audioLevel(snapshot.level)))
          if snapshot.terminalReason != nil { break }
        }
        consumeControls()
        try? await ContinuousClock().sleep(for: .milliseconds(34))
      }
      consumeControls()
      failureStage = "finishing microphone capture"
      let audio =
        try await
        (cancelled ? capture.cancel(sessionID: session.id) : capture.stop(sessionID: session.id))
      consumeControls()
      guard audio.sessionID == session.id else { throw AudioCaptureFailure.staleSession }
      Logger(subsystem: "org.localflow.LocalFlow", category: "dictation").notice(
        "Capture stopped: \(String(describing: audio.reason), privacy: .public); samples=\(audio.sampleCount)"
      )
      switch audio.reason {
      case .keyRelease:
        session.stopReason = .keyRelease
        session.bypassRewrite = bypassRewriteRequested
      case .durationLimit:
        session.stopReason = .durationLimit
        session.quality = .durationLimited
      case .cancelled:
        session.stopReason = .cancel
        session.quality = .incomplete
      case .failure(let failure):
        session.quality = .incomplete
        switch failure {
        case .overflow: session.stopReason = .overflow
        case .deviceLost: session.stopReason = .deviceLoss
        case .permissionRevoked: session.stopReason = .permissionRevoked
        case .sleep: session.stopReason = .sleep
        default: session.stopReason = .failure
        }
      }
      // A mailbox failure cannot become an ordinary key release merely because
      // the capture adapter stopped successfully. Capture's deadline also wins.
      if let reason = requestedStop, reason != .keyRelease {
        switch reason {
        case .durationLimit:
          if session.quality == .complete {
            session.stopReason = .durationLimit
            session.quality = .durationLimited
          }
        case .cancel:
          session.stopReason = .cancel
          session.quality = .incomplete
        case .overflow:
          session.stopReason = .overflow
          session.quality = .incomplete
        case .deviceLoss:
          session.stopReason = .deviceLoss
          session.quality = .incomplete
        case .permissionRevoked:
          session.stopReason = .permissionRevoked
          session.quality = .incomplete
        case .sleep:
          session.stopReason = .sleep
          session.quality = .incomplete
        case .failure:
          session.stopReason = .failure
          session.quality = .incomplete
        case .keyRelease: break
        }
      }
      transition(cancelled ? .cancelling : .transcribing)
      status = cancelled ? "Cancelling…" : "Transcribing locally…"
      failureStage = "transcribing audio"
      let result = await transcriber.transcribe(
        spool: audio.spool, lease: session.lease!, sampleCount: audio.sampleCount
      ).normalizedForDelivery(vocabulary: session.vocabulary ?? .empty)
      recognized = (result, audio.sampleCount)
      consumeControls()
      session.text = result.text
      if controlOverflow { session.stopReason = .overflow }
      if let reason = requestedStop, reason != .keyRelease, reason != .durationLimit {
        session.quality = .incomplete
      }
      if result.incomplete || result.detail?.incomplete == true || cancelled {
        session.quality = .incomplete
      }
      if !session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        failureStage = "saving the transcription"
        transition(.persisting)
        let entry = try TranscriptionEntry(
          id: session.id, text: session.text,
          createdAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1000),
          quality: session.quality, stopReason: session.stopReason,
          targetBundleID: session.target?.bundleIdentifier)
        var terminalReasons = result.completionReasons
        if cancelled { terminalReasons.append(.init(.cancelled)) }
        if session.stopReason == .durationLimit { terminalReasons.append(.init(.durationLimit)) }
        if session.stopReason != .keyRelease && session.stopReason != .durationLimit && !cancelled {
          terminalReasons.append(.init(.captureFailure))
        }
        if result.incomplete && result.detail?.incomplete == false {
          terminalReasons.append(.init(.failed))
        }
        let detail = try result.detail?.addingCompletionReasons(
          terminalReasons, normalizedText: entry.text)
        let envelope = TranscriptionEnvelope(entry: entry, detail: detail)
        let saved: TranscriptionEntry
        let persistStarted = DispatchTime.now().uptimeNanoseconds
        do {
          saved = try await store.commit(reservation: session.reservation!, envelope: envelope)
          persistenceNanoseconds = DispatchTime.now().uptimeNanoseconds &- persistStarted
          session.reservation = nil
          successfulDictation?(saved)
        } catch {
          unsavedEnvelope = envelope
          unsavedReservation = session.reservation
          session.reservation = nil
          throw error
        }
        let committedAt = ContinuousClock.now
        consumeControls()
        if allowsAutomaticInsertion, session.quality == .complete,
          session.stopReason == .keyRelease,
          let target = session.target
        {
          // The faithful transcript is saved and the ASR lease is released before
          // any request. Rewriting decides per attempt from a fresh snapshot; a
          // refusal or failure inserts the saved text with a notice.
          var textToInsert = saved.text
          var delivery = RewriteDelivery.faithful
          var notice: RewriteActionNotice?
          // A bypassed session is an eligibility outcome: admission is never
          // reached, so there is no row, no notice and no refusal metric.
          if let rewriter, !session.bypassRewrite {
            if let lease = session.lease {
              try await lifecycle.finish(lease)
              session.lease = nil
            }
            failureStage = "rewriting saved text"
            let admission = await rewriter.admit(
              dictation: saved.id, text: saved.text, mode: mode, committed: committedAt,
              context: .live)
            switch admission {
            case .notEligible: break
            case .refused(let reason):
              notice = RewriteActionNotice(
                dictationID: saved.id, message: RewriteNotice.text(for: reason, context: .live),
                canRetry: reason != .attemptLimit)
            case .admitted(let attempt):
              // Release all local capture resources before another dictation can
              // begin. The rewrite task owns only its bounded text snapshot.
              if let spool = session.audio {
                try await Task.detached { try spool.cleanup() }.value
                session.audio = nil
              }
              if let reservation = session.reservation {
                await store.releaseReservation(reservation)
                session.reservation = nil
              }
              pendingRewriteAttemptID = attempt.id
              transition(.rewriting)
              status = "Rewriting…"
              let outcome = await rewriter.complete(attemptID: attempt.id)
              guard controlTag == tag else { return }
              pendingRewriteAttemptID = nil
              switch outcome {
              case .rewritten(let text, let delivered):
                textToInsert = text
                delivery = RewriteDelivery(
                  source: .rewrite, attemptID: delivered.id, durationMilliseconds: nil)
              case .fallback(_, let category):
                notice = RewriteActionNotice(
                  dictationID: saved.id, message: RewriteNotice.text(for: category, context: .live),
                  canRetry: true)
              case .cancelled:
                notice = RewriteActionNotice(
                  dictationID: saved.id, message: RewriteNotice.cancelled(context: .live),
                  canRetry: true)
              case .refused(let reason):
                notice = RewriteActionNotice(
                  dictationID: saved.id, message: RewriteNotice.text(for: reason, context: .live),
                  canRetry: reason != .attemptLimit)
              case .notEligible: break
              }
            }
          }
          failureStage = "inserting saved text"
          transition(.inserting)
          storageBlocked = true
          let attempt = try await store.beginAttempt(id: saved.id, revision: saved.revision)
          consumeControls()
          let result: InsertionOutcome
          let handedOff = ContinuousClock.now
          if !allowsAutomaticInsertion {
            result = .notInserted(.unsupported)
          } else {
            result = await insertion.insertOnce(
              attemptID: attempt.id, target: target, text: textToInsert)
          }
          let outcome: TranscriptionStore.Outcome
          switch result {
          case .confirmed: outcome = .confirmed
          case .notInserted: outcome = .notInserted
          case .uncertain: outcome = .uncertain
          }
          if delivery.source == .rewrite {
            delivery = RewriteDelivery(
              source: .rewrite, attemptID: delivery.attemptID,
              durationMilliseconds: RewriteInstants.milliseconds(from: committedAt, to: handedOff))
          }
          pendingOutcome = (saved.id, attempt.entry.revision, attempt.id, outcome, delivery)
          _ = try await store.recordOutcome(
            id: saved.id, revision: attempt.entry.revision,
            attemptID: attempt.id, outcome: outcome, delivery: delivery)
          pendingOutcome = nil
          storageBlocked = false
          if let notice { setRewriteNotice(notice) }
          if outcome == .confirmed { insertionConfirmed?(textToInsert, target) }
          status = outcome == .confirmed ? "Ready" : "Text saved. Open LocalFlow to copy it."
          transition(outcome == .confirmed ? .idle : .recovery)
        } else {
          status = "Text saved for review. Open LocalFlow to copy it."
          transition(.recovery)
        }
      } else {
        if case .failure(let failure) = audio.reason, !cancelled {
          status = "Recording stopped. \(DictationErrorMessage.describe(failure))"
          transition(.failed)
        } else {
          status =
            cancelled
            ? "Cancelled"
            : (result.incomplete
              ? "Transcription failed. No text was produced." : "No speech detected.")
          transition(cancelled ? .idle : (result.incomplete ? .failed : .idle))
        }
      }
      if let lease = session.lease {
        if cancelled || session.quality == .incomplete {
          await lifecycle.cancelAndJoin(lease)
        } else {
          try await lifecycle.finish(lease)
        }
        session.lease = nil
      }
    } catch {
      let diagnostic = DictationErrorMessage.describe(error)
      Logger(subsystem: "org.localflow.LocalFlow", category: "dictation").error(
        "Dictation failed while \(failureStage, privacy: .public): \(diagnostic, privacy: .public)")
      _ = try? await capture.cancel(sessionID: session.id)
      if let lease = session.lease {
        await lifecycle.cancelAndJoin(lease)
      } else {
        await lifecycle.cancelSessionAndJoin(session.id)
      }
      status =
        unsaved != nil
        ? "Text is unsaved. Retry save or Copy before quitting."
        : (cancelled || stopRequested
          ? "Cancelled" : "Failed while \(failureStage). \(diagnostic)")
      if error as? TranscriptionStore.Error == .capacityExceeded {
        capacityBlocked = true
        status =
          "History is full. Explicitly delete saved entries before recording again. Dismissing recovery does not free space."
      }
      if storageBlocked {
        status = "Delivery status could not be saved. Retry storage before another dictation."
      }
      transition(cancelled && unsaved == nil ? .idle : .failed)
    }
    if let spool = session.audio {
      do { try await Task.detached { try spool.cleanup() }.value } catch {
        cleanupBlocked = true
        status = "Temporary audio cleanup failed. Restart after checking storage."
        transition(.failed)
      }
    }
    if let reservation = session.reservation { await store.releaseReservation(reservation) }
    await refreshHistory()
  }

  func setPreviewEnabled(_ enabled: Bool) {
    previewEnabled = enabled
    if !enabled { history = [] }
  }

  func verifyInitialAdmission() async {
    guard !busy, unsaved == nil else { return }
    busy = true
    defer { busy = false }
    do {
      let reservation = try await store.reserve()
      await store.releaseReservation(reservation)
    } catch TranscriptionStore.Error.capacityExceeded {
      capacityBlocked = true
      status = "History is full. Explicitly delete saved text before recording again."
      transition(.failed)
    } catch {
      storageBlocked = true
      status = "Storage is unavailable. Check free disk space and Retry storage."
      transition(.failed)
    }
  }

  func refreshHistory() async {
    if previewEnabled {
      let latest = try? await store.recent(limit: 1)
      if previewEnabled, let latest { history = latest }
    }
    hasRecovery = (try? await store.hasRecovery()) ?? hasRecovery
    if !hasRecovery, state == .recovery, unsaved == nil, !storageBlocked, !capacityBlocked {
      status = "Saved text reviewed."
      transition(.idle)
    }
    historyChanged?()
  }
  func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
  func retrySave() async {
    guard !busy, let envelope = unsavedEnvelope, let reservation = unsavedReservation else {
      return
    }
    busy = true
    defer { busy = false }
    do {
      _ = try await store.commit(reservation: reservation, envelope: envelope)
      self.unsavedEnvelope = nil
      unsavedReservation = nil
      status = "Text saved for review."
      transition(.recovery)
      await refreshHistory()
    } catch { status = "Still unsaved. Check available disk space or Copy the text." }
  }
  func discardUnsaved() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    if let reservation = unsavedReservation { await store.releaseReservation(reservation) }
    unsavedReservation = nil
    unsavedEnvelope = nil
    status = "Unsaved text discarded."
  }
  func retryStorage() async {
    guard !busy, storageBlocked else { return }
    busy = true
    defer { busy = false }
    do {
      if let (id, revision, attempt, outcome, delivery) = pendingOutcome {
        _ = try await store.recordOutcome(
          id: id, revision: revision, attemptID: attempt, outcome: outcome, delivery: delivery)
      } else {
        try await store.verifyWritable()
      }
      pendingOutcome = nil
      storageBlocked = false
      status = "Storage available. Saved text remains in history."
      await refreshHistory()
    } catch { status = "Storage is still unavailable. Existing text remains saved." }
  }

  func acquireExplicitInsertion(cancel: @escaping () -> Void) -> Bool {
    guard !busy, unsaved == nil, !storageBlocked, !cleanupBlocked else { return false }
    busy = true
    explicitCancellation = cancel
    return true
  }

  func finishExplicitInsertion(message: String) {
    explicitCancellation = nil
    busy = false
    status = message
  }

  func preserveExplicitOutcome(
    id: UUID, revision: Int64, attempt: UUID, outcome: TranscriptionStore.Outcome,
    delivery: RewriteDelivery = .faithful
  ) {
    pendingOutcome = (id, revision, attempt, outcome, delivery)
    storageBlocked = true
  }

  func dismissOrThrow(_ entry: TranscriptionEntry) async throws {
    guard !busy, !storageBlocked else { throw TranscriptionStore.Error.busy }
    busy = true
    defer { busy = false }
    _ = try await store.dismissRecovery(id: entry.id, revision: entry.revision)
    await refreshHistory()
  }

  func deleteOrThrow(_ entry: TranscriptionEntry) async throws {
    guard !busy, !storageBlocked else { throw TranscriptionStore.Error.busy }
    busy = true
    defer { busy = false }
    try await store.deleteConfirmed(id: entry.id, revision: entry.revision)
    if capacityBlocked {
      do {
        let reservation = try await store.reserve()
        await store.releaseReservation(reservation)
        capacityBlocked = false
        status = "History has space for another recording."
        if !storageBlocked, unsaved == nil, !cleanupBlocked { transition(.idle) }
      } catch {
        status =
          "History entry deleted. More space is needed before recording; explicitly delete another entry."
      }
    }
    await refreshHistory()
  }

  func dismiss(_ entry: TranscriptionEntry) async {
    do { try await dismissOrThrow(entry) } catch {
      status = "Could not update this entry. Try again."
    }
  }
  func delete(_ entry: TranscriptionEntry) async {
    do { try await deleteOrThrow(entry) } catch {
      status = "Could not delete this entry. It remains saved."
    }
  }
}
