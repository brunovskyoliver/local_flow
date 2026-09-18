import GRDB
import XCTest

@testable import LocalFlow

@MainActor
final class DictationCoordinatorTests: XCTestCase {
  private enum TestTimeout: Error { case expired }
  private var ownedDirectories: [URL] = []
  private var rigs: [RewriteRig] = []

  override func tearDown() async throws {
    let directories = await MainActor.run {
      for rig in rigs { rig.removeSuite() }
      rigs.removeAll()
      let result = ownedDirectories
      ownedDirectories.removeAll()
      return result
    }
    for directory in directories.reversed() { try? FileManager.default.removeItem(at: directory) }
  }

  func testProductionNormalizesAndSavesAllStagesBeforeDelivery() async throws {
    let store = try makeStore()
    let raw = " c\u{030C}au , svet  "
    let lifecycle = ModelLifecycleCoordinator { FakeRuntime(text: raw) }
    let insertion = FakeInsertion(store: store)
    let coordinator = try makeCoordinator(
      store: store, lifecycle: lifecycle,
      capture: FakeCapture(), insertion: insertion)
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }
    let rows = try await store.recent()
    let entry = try XCTUnwrap(rows.first)
    XCTAssertEqual(entry.text, "čau, svet")
    XCTAssertEqual(entry.deliveryState, .confirmed)
    XCTAssertTrue(insertion.sawAttempting)
    let savedDetail = try await store.qualityDetail(entry.id)
    let detail = try XCTUnwrap(savedDetail)
    XCTAssertEqual(Array(detail.rawWindows[0].text.utf8), Array(raw.utf8))
    XCTAssertEqual(Array(detail.assembledText.utf8), Array(raw.utf8))
    XCTAssertEqual(detail.normalizationVersion, TranscriptNormalizer.version)
    XCTAssertEqual(detail.appliedRuleIDs, ["N001", "N003", "N004"])
    XCTAssertNotNil(detail.provenance.stageDurations["normalization"])
    XCTAssertEqual(detail.normalizedHash, TranscriptionQualityDetail.hash(entry.text))
  }

  /// The other half of the Phase 3 checkpoint: the dependency absent entirely.
  /// Every other test in this suite runs it wired, rewriting off (T026).
  func testNilRewriterKeepsTheOriginalFlow() async throws {
    let store = try makeStore()
    let insertion = FakeInsertion(store: store)
    let coordinator = try makeCoordinator(
      store: store, lifecycle: ModelLifecycleCoordinator { FakeRuntime(text: "čau, svet") },
      capture: FakeCapture(), insertion: insertion, wireRewriter: false)
    var states: [DictationSession.State] = []
    coordinator.stateChanged = { states.append($0) }
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }
    XCTAssertFalse(states.contains(.rewriting))
    XCTAssertEqual(insertion.insertedTexts, ["čau, svet"])
    let entryFetched = try await store.recent().first
    let entry = try XCTUnwrap(entryFetched)
    XCTAssertEqual(entry.deliveryState, .confirmed)
    XCTAssertEqual(entry.rewriteState, .notRequested)
    XCTAssertEqual(entry.deliveredSource, .faithful)
  }

  func testProductionAppliesAdmissionSnapshotAndIgnoresLaterEdits() async throws {
    let store = try makeStore()
    let vocabulary = VocabularyStore(history: store)
    try await vocabulary.save(
      VocabularyEntry(id: "lf", canonical: "LocalFlow", aliases: ["local flow"]))
    let gate = Gate()
    let runtime = FakeRuntime(text: "use local flow, čau", gate: gate)
    let lifecycle = ModelLifecycleCoordinator { runtime }
    let insertion = FakeInsertion(store: store)
    let coordinator = try makeCoordinator(
      store: store, lifecycle: lifecycle, capture: FakeCapture(), insertion: insertion,
      vocabulary: vocabulary)
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    await runtime.waitUntilTranscribing()
    // An edit during the session changes the next session only.
    try await vocabulary.save(VocabularyEntry(id: "cau", canonical: "Čau", aliases: ["chau"]))
    await gate.openGate()
    try await waitUntil { !coordinator.busy }
    let rows = try await store.recent()
    let entry = try XCTUnwrap(rows.first)
    XCTAssertEqual(entry.text, "use LocalFlow, čau")
    XCTAssertEqual(entry.quality, .complete)
    XCTAssertEqual(entry.deliveryState, .confirmed)
    let savedDetail = try await store.qualityDetail(entry.id)
    let detail = try XCTUnwrap(savedDetail)
    XCTAssertEqual(detail.vocabularyRevision, 1)
    XCTAssertEqual(detail.appliedEntryIDs, ["lf"])
    XCTAssertEqual(detail.appliedRuleIDs, ["V001"])
    XCTAssertTrue(detail.ambiguousEntryIDs.isEmpty)
    XCTAssertEqual(detail.assembledText, "use local flow, čau")
    let current = try await vocabulary.contents().state
    XCTAssertEqual(current.revision, 2)
    XCTAssertNotEqual(detail.vocabularyHash, current.contentHash)
    let admitted = try VocabularyValidation.serialize([
      VocabularyEntry(id: "lf", canonical: "LocalFlow", aliases: ["local flow"])
    ])
    XCTAssertEqual(detail.vocabularyHash, TranscriptionQualityDetail.hash(admitted))
  }

  func testAmbiguousVocabularyLeavesTextAndWithholdsInsertion() async throws {
    let store = try makeStore()
    let vocabulary = VocabularyStore(history: store)
    try await vocabulary.save(VocabularyEntry(id: "x", canonical: "X", aliases: ["a b"]))
    try await vocabulary.save(VocabularyEntry(id: "y", canonical: "Y", aliases: ["b c"]))
    let insertion = FakeInsertion(store: store)
    let coordinator = try makeCoordinator(
      store: store, lifecycle: ModelLifecycleCoordinator { FakeRuntime(text: "a b c") },
      capture: FakeCapture(), insertion: insertion, vocabulary: vocabulary)
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }
    let rows = try await store.recent()
    let entry = try XCTUnwrap(rows.first)
    XCTAssertEqual(entry.text, "a b c")
    XCTAssertEqual(entry.quality, .incomplete)
    XCTAssertEqual(insertion.dispatchCount, 0)
    let savedDetail = try await store.qualityDetail(entry.id)
    let detail = try XCTUnwrap(savedDetail)
    XCTAssertEqual(detail.ambiguousEntryIDs, ["x", "y"])
    XCTAssertTrue(detail.appliedEntryIDs.isEmpty)
    XCTAssertTrue(detail.completionReasons.contains(.init(.ambiguousVocabulary)))
  }

  func testVocabularyLoadFailureBlocksAdmissionBeforeCapture() async throws {
    struct Failing: VocabularyProviding {
      func snapshot() async throws -> VocabularySnapshot {
        throw VocabularyEditError(field: .store, code: .damaged)
      }
    }
    let capture = FakeCapture()
    let store = try makeStore()
    let coordinator = try makeCoordinator(
      store: store, capture: capture, vocabulary: Failing())
    coordinator.begin()
    try await waitUntil { !coordinator.busy }
    XCTAssertEqual(coordinator.state, .failed)
    XCTAssertEqual(
      coordinator.status,
      "Failed while loading preferred spellings. Preferred spellings could not be loaded. Repair or delete entries in Settings."
    )
    let starts = await capture.starts
    XCTAssertEqual(starts, 0)
    let rows = try await store.recent()
    XCTAssertTrue(rows.isEmpty)
    XCTAssertTrue(coordinator.canBegin)
  }

  func testProductionUnexpectedControlsRequireReviewAndPreserveRaw() async throws {
    let store = try makeStore()
    let insertion = FakeInsertion(store: store)
    let coordinator = try makeCoordinator(
      store: store,
      lifecycle: ModelLifecycleCoordinator { FakeRuntime(text: " hello\u{0001} world ") },
      capture: FakeCapture(), insertion: insertion)
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }
    let rows = try await store.recent()
    XCTAssertEqual(rows.first?.text, "hello\u{0001} world")
    XCTAssertEqual(rows.first?.quality, .incomplete)
    XCTAssertEqual(insertion.dispatchCount, 0)
  }

  func testReleaseDuringPreparationDoesNotStartCapture() async throws {
    let gate = Gate()
    let runtime = FakeRuntime(gate: gate)
    let lifecycle = ModelLifecycleCoordinator {
      await gate.wait()
      return runtime
    }
    let capture = FakeCapture()
    let insertion = FakeInsertion()
    let coordinator = try makeCoordinator(
      lifecycle: lifecycle, capture: capture, insertion: insertion)

    coordinator.begin()
    try await waitUntil { coordinator.state == .preparing }
    coordinator.release()
    await gate.openGate()
    try await waitUntil { !coordinator.busy }
    let starts = await capture.starts
    XCTAssertEqual(starts, 0)
  }

  func testCompleteResultIsCommittedBeforeInsertionAndConfirmed() async throws {
    let store = try makeStore()
    let lifecycle = ModelLifecycleCoordinator { FakeRuntime() }
    let capture = FakeCapture()
    let insertion = FakeInsertion(store: store)
    let coordinator = try makeCoordinator(
      store: store, lifecycle: lifecycle, capture: capture, insertion: insertion)

    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }
    XCTAssertEqual(insertion.dispatchCount, 1)
    XCTAssertTrue(insertion.sawAttempting)
    let entry = try await store.recent(limit: 1).first
    XCTAssertEqual(entry?.deliveryState, .confirmed)
  }

  func testSavedDictationRefreshesVisibleHistoryWithoutNavigation() async throws {
    for outcome: InsertionOutcome in [.confirmed, .uncertain(.unsupported)] {
      let store = try makeStore()
      let history = HistoryViewModel(store: store)
      let insertion = FakeInsertion(store: store)
      insertion.outcome = outcome
      let coordinator = try makeCoordinator(
        store: store, lifecycle: ModelLifecycleCoordinator { FakeRuntime() },
        capture: FakeCapture(), insertion: insertion)
      coordinator.historyChanged = { history.refresh() }
      history.refresh()
      try await waitUntil { !history.isLoading }
      XCTAssertTrue(history.entries.isEmpty)
      coordinator.begin()
      try await waitUntil { coordinator.state == .recording }
      coordinator.release()
      try await waitUntil { !coordinator.busy && !history.isLoading }
      XCTAssertEqual(history.entries.count, 1)
      XCTAssertEqual(
        history.entries.first?.deliveryState, outcome == .confirmed ? .confirmed : .uncertain)
    }
  }

  func testDurationLimitIsReviewOnly() async throws {
    let store = try makeStore()
    let lifecycle = ModelLifecycleCoordinator { FakeRuntime() }
    let capture = FakeCapture(reason: .durationLimit)
    let insertion = FakeInsertion(store: store)
    let coordinator = try makeCoordinator(
      store: store, lifecycle: lifecycle, capture: capture, insertion: insertion)

    coordinator.begin()
    try await waitUntil { !coordinator.busy }
    XCTAssertEqual(insertion.dispatchCount, 0)
    let durationEntry = try await store.recent(limit: 1).first
    XCTAssertEqual(durationEntry?.quality, .durationLimited)
  }

  func testDeadlineResultWinsOrdinaryRelease() async throws {
    let store = try makeStore()
    let insertion = FakeInsertion(store: store)
    let coordinator = try makeCoordinator(
      store: store, capture: FakeCapture(reason: .durationLimit, staleSnapshot: true),
      insertion: insertion)
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }
    let entry = try await store.recent().first
    XCTAssertEqual(entry?.quality, .durationLimited)
    XCTAssertEqual(entry?.stopReason, .durationLimit)
    XCTAssertEqual(insertion.dispatchCount, 0)
  }

  func testRepeatedBeginStartsOneSession() async throws {
    let capture = FakeCapture()
    let coordinator = try makeCoordinator(capture: capture)
    coordinator.begin()
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }
    let starts = await capture.starts
    XCTAssertEqual(starts, 1)
  }

  func testCancellationRetainsCommittedText() async throws {
    let store = try makeStore()
    let lifecycle = ModelLifecycleCoordinator { FakeRuntime() }
    let capture = FakeCapture()
    let dispatchGate = Gate()
    let insertion = FakeInsertion(store: store, dispatchGate: dispatchGate)
    let coordinator = try makeCoordinator(
      store: store, lifecycle: lifecycle, capture: capture, insertion: insertion)

    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { insertion.dispatchCount == 1 }
    coordinator.cancel()
    await dispatchGate.openGate()
    try await waitUntil { !coordinator.busy }
    let entry = try await store.recent(limit: 1).first
    XCTAssertEqual(entry?.text, "hello")
    XCTAssertEqual(insertion.dispatchCount, 1)
  }

  func testMailboxOverflowStopsPreparationWithoutCaptureAndReportsFailure() async throws {
    let mailbox = ControlMailbox()
    let capture = FakeCapture()
    let coordinator = try makeCoordinator(capture: capture, mailbox: mailbox)
    coordinator.begin()
    let tag = try XCTUnwrap(coordinator.controlTag)
    for _ in 0..<ControlMailbox.capacity {
      _ = mailbox.tryEnqueue(.init(tag: tag, value: .begin))
    }
    coordinator.release()
    coordinator.cancel()
    try await waitUntil { !coordinator.busy }
    XCTAssertEqual(coordinator.state, .failed)
    XCTAssertTrue(coordinator.status.contains("overflowed"))
    let starts = await capture.starts
    XCTAssertEqual(starts, 0)
    XCTAssertEqual(mailbox.consumeFlags(for: tag).terminal, .failed)
  }

  func testMailboxFailureStopsAreAlwaysReviewOnly() async throws {
    for reason in [
      ControlMailbox.StopReason.overflow, .deviceLoss, .permissionRevoked, .sleep, .failure,
      .durationLimit,
    ] {
      let mailbox = ControlMailbox()
      let store = try makeStore()
      let insertion = FakeInsertion(store: store)
      let coordinator = try makeCoordinator(
        store: store, capture: FakeCapture(), insertion: insertion, mailbox: mailbox)
      coordinator.begin()
      try await waitUntil { coordinator.state == .recording }
      let tag = try XCTUnwrap(coordinator.controlTag)
      XCTAssertTrue(mailbox.tryEnqueue(.init(tag: tag, value: .stop(reason))))
      try await waitUntil { !coordinator.busy }
      let entry = try await store.recent().first
      XCTAssertEqual(entry?.quality, reason == .durationLimit ? .durationLimited : .incomplete)
      XCTAssertEqual(insertion.dispatchCount, 0)
    }
  }

  func testLateFailureBeforeOrAfterAttemptMarkerPreventsDispatch() async throws {
    for phase in [DictationSession.State.persisting, .inserting] {
      for reason in [ControlMailbox.StopReason.failure, .durationLimit] {
        let mailbox = ControlMailbox()
        let store = try makeStore()
        let insertion = FakeInsertion(store: store)
        let coordinator = try makeCoordinator(
          store: store, capture: FakeCapture(), insertion: insertion, mailbox: mailbox)
        coordinator.stateChanged = { [weak coordinator] state in
          if state == phase, let tag = coordinator?.controlTag {
            mailbox.requestStop(reason, for: tag)
          }
        }
        coordinator.begin()
        try await waitUntil { coordinator.state == .recording }
        coordinator.release()
        try await waitUntil { !coordinator.busy }
        let rows = try await store.recent()
        XCTAssertEqual(rows.first?.text, "hello")
        XCTAssertEqual(rows.first?.recoveryState, .needsReview)
        XCTAssertEqual(insertion.dispatchCount, 0)
      }
    }
  }

  func testStaleCancellationCannotStopNextSession() async throws {
    let mailbox = ControlMailbox()
    let capture = FakeCapture()
    let coordinator = try makeCoordinator(capture: capture, mailbox: mailbox)
    coordinator.begin()
    let old = try XCTUnwrap(coordinator.controlTag)
    coordinator.release()
    try await waitUntil { !coordinator.busy }
    coordinator.begin()
    XCTAssertFalse(mailbox.requestCancel(for: old))
    XCTAssertFalse(mailbox.requestStop(.durationLimit, for: old))
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }
    XCTAssertEqual(coordinator.state, .idle)
  }

  func testEscapeDuringDecodeJoinsAndPreservesReturnedPrefixWithoutInsertion() async throws {
    let gate = Gate()
    let runtime = FakeRuntime(gate: gate)
    let store = try makeStore()
    let insertion = FakeInsertion(store: store)
    let coordinator = try makeCoordinator(
      store: store, lifecycle: ModelLifecycleCoordinator { runtime },
      capture: FakeCapture(), insertion: insertion)
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { coordinator.state == .transcribing }
    // Let the fake runtime enter its uninterruptible call before cancelling.
    await runtime.waitUntilTranscribing()
    coordinator.cancel()
    try await waitUntil { coordinator.state == .cancelling }
    XCTAssertTrue(coordinator.busy)
    coordinator.begin()
    await gate.openGate()
    try await waitUntil { !coordinator.busy }
    let entries = try await store.recent()
    XCTAssertEqual(entries.first?.text, "hello")
    XCTAssertEqual(entries.first?.quality, .incomplete)
    XCTAssertEqual(insertion.dispatchCount, 0)
  }

  func testCaptureFailureWithNoAudioReportsCauseInsteadOfSilence() async throws {
    let capture = FakeCapture(reason: .failure(.unsupportedFormat), samples: [])
    let coordinator = try makeCoordinator(
      lifecycle: ModelLifecycleCoordinator { FakeRuntime() }, capture: capture)
    coordinator.begin()
    try await waitUntil { !coordinator.busy }
    XCTAssertEqual(coordinator.state, .failed)
    XCTAssertTrue(coordinator.status.contains("microphone format is unsupported"))
    XCTAssertFalse(coordinator.status.contains("No speech detected"))
  }

  func testDeniedMicrophoneNeverLoadsRuntimeOrStartsCapture() async throws {
    let capture = FakeCapture(authorized: false)
    let lifecycle = ModelLifecycleCoordinator {
      XCTFail("Permission denial must precede model loading")
      return FakeRuntime()
    }
    let coordinator = try makeCoordinator(lifecycle: lifecycle, capture: capture)
    coordinator.begin()
    try await waitUntil { !coordinator.busy }
    let starts = await capture.starts
    XCTAssertEqual(starts, 0)
    XCTAssertEqual(coordinator.state, .failed)
    XCTAssertTrue(coordinator.status.contains("requesting microphone access"))
    XCTAssertTrue(coordinator.status.contains("Microphone access is not allowed"))
  }

  func testCancellationWhileCaptureStartsJoinsWithoutShowingRecording() async throws {
    let gate = Gate()
    let capture = FakeCapture(startGate: gate)
    let coordinator = try makeCoordinator(capture: capture)
    var showedRecording = false
    coordinator.stateChanged = { if $0 == .recording { showedRecording = true } }
    coordinator.begin()
    await capture.waitUntilStarting()
    coordinator.cancel()
    try await waitUntil { coordinator.state == .cancelling }
    XCTAssertTrue(coordinator.busy)
    await gate.openGate()
    try await waitUntil { !coordinator.busy }
    let cancels = await capture.cancels
    XCTAssertGreaterThan(cancels, 0)
    XCTAssertFalse(showedRecording)
  }

  func testStaleCaptureSnapshotCannotFinishCurrentRecording() async throws {
    let capture = FakeCapture(reason: .durationLimit, staleSnapshot: true)
    let coordinator = try makeCoordinator(capture: capture)
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    try await ContinuousClock().sleep(for: .milliseconds(100))
    XCTAssertEqual(coordinator.state, .recording)
    coordinator.release()
    try await waitUntil { !coordinator.busy }
  }

  func testStaleCaptureCompletionNeverReachesDecoderOrInsertion() async throws {
    let store = try makeStore()
    let insertion = FakeInsertion(store: store)
    let coordinator = try makeCoordinator(
      store: store, capture: FakeCapture(staleResult: true), insertion: insertion)
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }
    let entries = try await store.recent()
    XCTAssertTrue(entries.isEmpty)
    XCTAssertEqual(insertion.dispatchCount, 0)
    XCTAssertEqual(coordinator.state, .failed)
  }

  func testSilenceCreatesNoHistoryOrDispatch() async throws {
    let store = try makeStore()
    let insertion = FakeInsertion(store: store)
    let coordinator = try makeCoordinator(
      store: store, lifecycle: ModelLifecycleCoordinator { FakeRuntime(text: "  ") },
      capture: FakeCapture(), insertion: insertion)
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }
    let entries = try await store.recent()
    XCTAssertTrue(entries.isEmpty)
    XCTAssertEqual(insertion.dispatchCount, 0)
    XCTAssertEqual(coordinator.status, "No speech detected.")
  }

  func testPersistentAttentionIncludesRecoveryOlderThanVisibleHistory() async throws {
    let store = try makeStore()
    var oldest: TranscriptionEntry?
    for index in 0..<21 {
      let entry = try TranscriptionEntry(
        id: UUID(), text: "Entry \(index)",
        createdAtMilliseconds: Int64(index), quality: .incomplete, stopReason: .cancel)
      let reservation = try await store.reserve()
      let saved = try await store.commit(reservation: reservation, entry: entry)
      if index == 0 {
        oldest = saved
      } else {
        _ = try await store.dismissRecovery(id: saved.id, revision: saved.revision)
      }
    }
    let coordinator = try makeCoordinator(store: store, capture: FakeCapture())
    coordinator.setPreviewEnabled(true)
    await coordinator.refreshHistory()
    XCTAssertEqual(coordinator.history.count, 1)
    XCTAssertFalse(coordinator.history.contains { $0.recoveryState == .needsReview })
    XCTAssertTrue(coordinator.hasRecovery)
    try await coordinator.dismissOrThrow(XCTUnwrap(oldest))
    XCTAssertFalse(coordinator.hasRecovery)
    let retained = try await store.get(XCTUnwrap(oldest).id)
    XCTAssertEqual(retained?.quality, .incomplete)
  }

  func testDismissingLastRecoveryClearsRecoveryPresentation() async throws {
    let store = try makeStore()
    let coordinator = try makeCoordinator(
      store: store,
      capture: FakeCapture(reason: .durationLimit))
    coordinator.begin()
    try await waitUntil { !coordinator.busy }
    coordinator.setPreviewEnabled(true)
    await coordinator.refreshHistory()
    XCTAssertEqual(coordinator.state, .recovery)
    XCTAssertTrue(coordinator.hasRecovery)
    let entry = try XCTUnwrap(coordinator.history.first)
    try await coordinator.dismissOrThrow(entry)
    XCTAssertFalse(coordinator.hasRecovery)
    XCTAssertEqual(coordinator.state, .idle)
    XCTAssertEqual(coordinator.history.first?.quality, .durationLimited)
  }

  func testFullHistoryBlocksCaptureUntilConfirmedDeletionFreesCapacity() async throws {
    let root = try makeSpoolRoot()
    ownedDirectories.append(root)
    let path = root.appendingPathComponent("history.sqlite").path
    let store = try TranscriptionStore(path: path)
    let fixture = try DatabaseQueue(path: path)
    try await fixture.write { db in
      for index in 0..<TranscriptionStore.maximumRows {
        try db.execute(
          sql: """
            INSERT INTO transcriptions
              (id, text, created_at, delivery_state, recovery_state, quality, stop_reason, revision)
            VALUES (?, 'Saved', ?, 'not_attempted', 'needs_review', 'complete', 'key_release', 0)
            """, arguments: [UUID().uuidString, index])
      }
      try db.execute(
        sql: "UPDATE history_usage SET row_count = ?, payload_bytes = ? WHERE id = 1",
        arguments: [TranscriptionStore.maximumRows, TranscriptionStore.maximumRows * 5])
    }
    let capture = FakeCapture()
    let coordinator = try makeCoordinator(store: store, capture: capture)
    await coordinator.verifyInitialAdmission()
    XCTAssertFalse(
      coordinator.canBegin, "First-run readiness must reject full history before a hold")
    coordinator.begin()
    try await waitUntil { !coordinator.busy }
    XCTAssertTrue(coordinator.capacityBlocked)
    coordinator.setPreviewEnabled(true)
    await coordinator.refreshHistory()
    XCTAssertTrue(coordinator.status.contains("Explicitly delete"))
    let starts = await capture.starts
    XCTAssertEqual(starts, 0)
    let entry = try XCTUnwrap(coordinator.history.first)
    try await coordinator.dismissOrThrow(entry)
    XCTAssertTrue(coordinator.capacityBlocked)
    coordinator.begin()
    XCTAssertFalse(coordinator.busy)
    let dismissed = try await store.get(entry.id)
    try await coordinator.deleteOrThrow(XCTUnwrap(dismissed))
    XCTAssertFalse(coordinator.capacityBlocked)
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.cancel()
    try await waitUntil { !coordinator.busy }
  }

  func testFullEnvelopeRemainsReviewOnlyForDurationAndCaptureFailures() async throws {
    for reason: AudioCaptureStopReason in [
      .durationLimit, .failure(.permissionRevoked), .failure(.deviceLost),
    ] {
      let store = try makeStore()
      let authored = try makeQualityEnvelope()
      let insertion = FakeInsertion()
      let transcriber = FakeDictationTranscriber(
        result: .init(text: authored.entry.text, incomplete: false, detail: authored.detail))
      let coordinator = try makeCoordinator(
        store: store, capture: FakeCapture(reason: reason), insertion: insertion,
        transcriber: transcriber)
      coordinator.begin()
      try await waitUntil { !coordinator.busy }
      let rows = try await store.recent()
      let row = try XCTUnwrap(rows.first)
      let detail = try await store.qualityDetail(row.id)
      XCTAssertTrue(try XCTUnwrap(detail).incomplete)
      XCTAssertNotEqual(row.quality, .complete)
      XCTAssertEqual(insertion.dispatchCount, 0)
      XCTAssertEqual(
        detail?.rawWindows.first?.textHash, authored.detail?.rawWindows.first?.textHash)
      XCTAssertTrue(
        detail?.completionReasons.contains {
          $0.code == (reason == .durationLimit ? .durationLimit : .captureFailure)
        } == true)
    }
  }

  func testCancellationJoinsFullResultBeforeRecoveryAndKeepsRawEvidence() async throws {
    let store = try makeStore()
    let gate = Gate()
    let authored = try makeQualityEnvelope()
    let insertion = FakeInsertion()
    let transcriber = FakeDictationTranscriber(
      result: .init(text: authored.entry.text, incomplete: false, detail: authored.detail),
      gate: gate)
    let coordinator = try makeCoordinator(
      store: store, capture: FakeCapture(), insertion: insertion, transcriber: transcriber)
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { coordinator.state == .transcribing }
    coordinator.cancel()
    try await waitUntil { coordinator.state == .cancelling }
    XCTAssertTrue(coordinator.busy)
    XCTAssertFalse(coordinator.canBegin)
    await gate.openGate()
    try await waitUntil { !coordinator.busy }
    let rows = try await store.recent()
    let row = try XCTUnwrap(rows.first)
    let detail = try await store.qualityDetail(row.id)
    XCTAssertEqual(row.quality, .incomplete)
    XCTAssertTrue(detail?.completionReasons.contains { $0.code == .cancelled } == true)
    XCTAssertEqual(detail?.rawWindows.first?.textHash, authored.detail?.rawWindows.first?.textHash)
    XCTAssertEqual(insertion.dispatchCount, 0)
  }

  func testModelLoadFailureReleasesAdmissionWithoutStartingCapture() async throws {
    let store = try makeStore()
    let capture = FakeCapture()
    let insertion = FakeInsertion()
    let lifecycle = ModelLifecycleCoordinator { throw DictationFailure.modelUnavailable }
    let coordinator = try makeCoordinator(
      store: store, lifecycle: lifecycle, capture: capture, insertion: insertion)
    coordinator.begin()
    try await waitUntil { !coordinator.busy }
    let starts = await capture.starts
    XCTAssertEqual(starts, 0)
    XCTAssertEqual(insertion.dispatchCount, 0)
    XCTAssertNil(coordinator.unsavedEnvelope)
    let reservation = try await store.reserve()
    await store.releaseReservation(reservation)
  }

  /// SC-001 guard (T026): every test in this suite runs with the rewrite
  /// coordinator wired exactly as `AppServices` wires it, rewriting off and a
  /// transport that fails the test if it is ever called. Tests that exercise
  /// rewriting pass their own rig.
  @discardableResult
  private func makeRig(store: any RewriteAttemptStoring, _ rig: RewriteRig? = nil) -> RewriteRig {
    let rig = rig ?? RewriteRig(store: store)
    rigs.append(rig)
    return rig
  }

  private func makeCoordinator(
    store: TranscriptionStore? = nil,
    lifecycle: ModelLifecycleCoordinator? = nil,
    capture: any AudioCapturing,
    insertion: (any TextInserting)? = nil,
    mailbox: ControlMailbox = ControlMailbox(),
    transcriber: (any DictationTranscribing)? = nil,
    vocabulary: (any VocabularyProviding)? = nil,
    rewrite: RewriteRig? = nil,
    wireRewriter: Bool = true
  ) throws -> DictationCoordinator {
    let actualStore: TranscriptionStore
    if let store { actualStore = store } else { actualStore = try makeStore() }
    let actualLifecycle = lifecycle ?? ModelLifecycleCoordinator { FakeRuntime() }
    let actualInsertion = insertion ?? FakeInsertion()
    let spoolRoot = try makeSpoolRoot()
    ownedDirectories.append(spoolRoot)
    let rig = wireRewriter ? makeRig(store: actualStore, rewrite) : nil
    return DictationCoordinator(
      store: actualStore, lifecycle: actualLifecycle, capture: capture, insertion: actualInsertion,
      spoolRoot: spoolRoot, mailbox: mailbox, transcriber: transcriber, vocabulary: vocabulary,
      rewriter: rig?.coordinator)
  }

  private func makeStore() throws -> TranscriptionStore {
    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("LocalFlowStore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    ownedDirectories.append(directory)
    return try TranscriptionStore(path: directory.appendingPathComponent("history.sqlite").path)
  }

  private func waitUntil(
    _ predicate: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !predicate() {
      guard clock.now < deadline else {
        XCTFail("timed out")
        throw TestTimeout.expired
      }
      await Task.yield()
    }
  }
}

/// US1 (T025): the live dictation flow with the rewrite coordinator wired.
/// The suite above is the SC-001 guard — it runs with the same wiring, rewriting
/// off and a `failOnAnyCall` transport.
@MainActor
final class DictationRewriteTests: XCTestCase {
  private enum TestTimeout: Error { case expired }
  private var ownedDirectories: [URL] = []
  private var rigs: [RewriteRig] = []

  override func tearDown() async throws {
    let directories = await MainActor.run {
      for rig in rigs { rig.removeSuite() }
      rigs.removeAll()
      let result = ownedDirectories
      ownedDirectories.removeAll()
      return result
    }
    for directory in directories.reversed() { try? FileManager.default.removeItem(at: directory) }
  }

  private let faithful = "move the odoo deployment to monday"

  func testWiredButDisabledLeavesTheFaithfulFlowUntouched() async throws {
    let (coordinator, fixture) = try makeFixture()
    try await dictate(coordinator)
    XCTAssertEqual(fixture.rig.callCount, 0)
    XCTAssertEqual(fixture.insertion.insertedTexts, [faithful])
    let entryFetched = try await fixture.store.recent().first
    let entry = try XCTUnwrap(entryFetched)
    XCTAssertEqual(entry.text, faithful)
    XCTAssertEqual(entry.rewriteState, .notRequested)
    XCTAssertEqual(entry.deliveredSource, .faithful)
    let attempts = try await fixture.store.attempts(for: entry.id)
    XCTAssertTrue(attempts.isEmpty)
  }

  func testEnabledInsertsTheRewrittenTextAndRecordsTheAttempt() async throws {
    let gate = Gate()
    let (coordinator, fixture) = try makeFixture(
      enabled: true,
      script: .after(gate, then: .succeed(text: "Move the Odoo deployment to Monday.")))
    var states: [DictationSession.State] = []
    coordinator.stateChanged = { states.append($0) }
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { coordinator.state == .rewriting }
    XCTAssertEqual(fixture.insertion.dispatchCount, 0, "insertion waits for the rewrite")
    let pending = try await fixture.store.recent().first
    XCTAssertEqual(pending?.rewriteState, .pending)
    await gate.openGate()
    try await waitUntil { !coordinator.busy }
    XCTAssertEqual(fixture.insertion.insertedTexts, ["Move the Odoo deployment to Monday."])
    XCTAssertEqual(fixture.rig.callCount, 1)
    XCTAssertEqual(
      states.filter { $0 == .persisting || $0 == .rewriting || $0 == .inserting },
      [.persisting, .rewriting, .inserting])
    let entryFetched = try await fixture.store.recent().first
    let entry = try XCTUnwrap(entryFetched)
    XCTAssertEqual(entry.text, faithful, "the faithful transcript is what is stored")
    XCTAssertEqual(entry.rewriteState, .succeeded)
    XCTAssertEqual(entry.deliveredSource, .rewrite)
    let attempts = try await fixture.store.attempts(for: entry.id)
    XCTAssertEqual(attempts.count, 1)
    XCTAssertEqual(attempts.first?.state, .succeeded)
    XCTAssertEqual(entry.deliveredRewriteAttemptID, attempts.first?.id)
    XCTAssertEqual(attempts.first?.outputText, "Move the Odoo deployment to Monday.")
  }

  func testUnreachableServerInsertsTheFaithfulTextWithARetryNotice() async throws {
    let (coordinator, fixture) = try makeFixture(
      enabled: true, script: .fail(.serverUnreachable))
    var notices: [RewriteActionNotice?] = []
    coordinator.rewriteNoticeChanged = { notices.append($0) }
    try await dictate(coordinator)
    XCTAssertEqual(fixture.insertion.insertedTexts, [faithful])
    let notice = try XCTUnwrap(notices.compactMap { $0 }.last)
    XCTAssertEqual(notice.message, "Rewrite server unreachable. Original text inserted.")
    XCTAssertTrue(notice.canRetry)
    let entryFetched = try await fixture.store.recent().first
    let entry = try XCTUnwrap(entryFetched)
    XCTAssertEqual(entry.text, faithful)
    XCTAssertEqual(entry.rewriteState, .failed)
    XCTAssertEqual(entry.deliveredSource, .faithful)
    let attempts = try await fixture.store.attempts(for: entry.id)
    XCTAssertEqual(attempts.count, 1)
  }

  // FR-022: exercise failure delivery through the real store and insertion boundary.
  private func assertFaithfulFallback(_ script: FakeRewriteTransport.Script) async throws {
    let (coordinator, fixture) = try makeFixture(enabled: true, script: script)
    try await dictate(coordinator)
    let fetched = try await fixture.store.recent().first
    let entry = try XCTUnwrap(fetched)
    XCTAssertEqual(entry.text, faithful)
    XCTAssertEqual(fixture.insertion.insertedTexts, [faithful])
    XCTAssertEqual(entry.deliveredSource, .faithful)
    XCTAssertNil(entry.deliveredRewriteAttemptID)
    let attempts = try await fixture.store.attempts(for: entry.id)
    XCTAssertEqual(attempts.count, 1)
    XCTAssertEqual(attempts.first?.inputText, faithful)
    XCTAssertNil(attempts.first?.outputText)
    XCTAssertNotEqual(attempts.first?.state, .succeeded)
  }

  func testMalformedResponsePreservesFaithfulFallback() async throws {
    try await assertFaithfulFallback(.malformed)
  }

  func testWrongSchemaVersionPreservesFaithfulFallback() async throws {
    try await assertFaithfulFallback(.fail(.unsupportedSchemaVersion))
  }

  func testEmptyResponsePreservesFaithfulFallback() async throws {
    try await assertFaithfulFallback(.succeed(text: ""))
  }

  func testOversizedResponsePreservesFaithfulFallback() async throws {
    try await assertFaithfulFallback(.oversized)
  }

  func testAuthenticationFailurePreservesFaithfulFallback() async throws {
    try await assertFaithfulFallback(.httpStatus(401, code: "unauthorized"))
  }

  func testMismatchedResponsePreservesFaithfulFallback() async throws {
    try await assertFaithfulFallback(.succeed(text: "Wrong request.", responseID: UUID()))
  }

  func testTimeoutPreservesFaithfulFallback() async throws {
    try await assertFaithfulFallback(.fail(.timeout))
  }

  func testPreAdmissionRefusalInsertsAtOnceAndLeavesNoRow() async throws {
    // An https endpoint with no stored credential: refused before any row.
    let (coordinator, fixture) = try makeFixture(
      enabled: true, endpoint: "https://rewrite.example", failOnAnyCall: true)
    var notices: [RewriteActionNotice?] = []
    coordinator.rewriteNoticeChanged = { notices.append($0) }
    try await dictate(coordinator)
    XCTAssertEqual(fixture.insertion.insertedTexts, [faithful])
    XCTAssertEqual(fixture.rig.callCount, 0)
    let notice = try XCTUnwrap(notices.compactMap { $0 }.last)
    XCTAssertEqual(
      notice.message, "Rewriting skipped: no credential for this server. Original text inserted.")
    let entryFetched = try await fixture.store.recent().first
    let entry = try XCTUnwrap(entryFetched)
    XCTAssertEqual(entry.text, faithful)
    XCTAssertEqual(entry.rewriteState, .notRequested)
    XCTAssertEqual(entry.deliveredSource, .faithful)
    let attempts = try await fixture.store.attempts(for: entry.id)
    XCTAssertTrue(attempts.isEmpty)
  }

  /// T026: the other half of the SC-001 gate — rewriting on, Exact selected.
  func testExactModeSendsNothingWithRewritingEnabled() async throws {
    let (coordinator, fixture) = try makeFixture(enabled: true, mode: .exact, failOnAnyCall: true)
    var states: [DictationSession.State] = []
    coordinator.stateChanged = { states.append($0) }
    try await dictate(coordinator)
    XCTAssertEqual(fixture.rig.callCount, 0)
    XCTAssertFalse(states.contains(.rewriting))
    XCTAssertEqual(fixture.insertion.insertedTexts, [faithful])
    let entryFetched = try await fixture.store.recent().first
    let entry = try XCTUnwrap(entryFetched)
    XCTAssertEqual(entry.rewriteState, .notRequested)
    let attempts = try await fixture.store.attempts(for: entry.id)
    XCTAssertTrue(attempts.isEmpty)
  }

  func testIncompleteResultNeverEntersRewriting() async throws {
    let (coordinator, fixture) = try makeFixture(
      enabled: true, quality: .incomplete, failOnAnyCall: true)
    var states: [DictationSession.State] = []
    coordinator.stateChanged = { states.append($0) }
    try await dictate(coordinator)
    XCTAssertEqual(fixture.rig.callCount, 0)
    XCTAssertFalse(states.contains(.rewriting))
    let entryFetched = try await fixture.store.recent().first
    let entry = try XCTUnwrap(entryFetched)
    XCTAssertEqual(entry.rewriteState, .notRequested)
    let attempts = try await fixture.store.attempts(for: entry.id)
    XCTAssertTrue(attempts.isEmpty)
  }

  func testTogglingThePreferenceAppliesToTheNextDictationWithoutRelaunch() async throws {
    let (coordinator, fixture) = try makeFixture(script: .succeed(text: "Rewritten."))
    try await dictate(coordinator)
    XCTAssertEqual(fixture.rig.callCount, 0)
    fixture.rig.preferences.rewriteEnabled = true
    try await dictate(coordinator)
    XCTAssertEqual(fixture.rig.callCount, 1)
    XCTAssertEqual(fixture.insertion.insertedTexts.last, "Rewritten.")
    fixture.rig.preferences.rewriteEnabled = false
    try await dictate(coordinator)
    XCTAssertEqual(fixture.rig.callCount, 1, "the third dictation sends nothing")
    XCTAssertEqual(fixture.insertion.insertedTexts.last, faithful)
  }

  func testPendingAttemptKeepsItsSnapshotWhenSettingsChange() async throws {
    let gate = Gate()
    let (coordinator, fixture) = try makeFixture(
      enabled: true, script: .after(gate, then: .succeed(text: "Rewritten.")))
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { coordinator.state == .rewriting }
    // Everything the snapshot carries changes while the attempt is in flight.
    fixture.rig.preferences.rewriteEnabled = false
    fixture.rig.preferences.rewriteDefaultMode = .concise
    fixture.rig.preferences.rewriteTimeoutSeconds = 30
    await gate.openGate()
    try await waitUntil { !coordinator.busy }
    let recorded = try XCTUnwrap(fixture.rig.transport.recorded.first)
    XCTAssertEqual(recorded.request.mode, .clean)
    XCTAssertEqual(recorded.timeout, .seconds(5))
    XCTAssertEqual(fixture.insertion.insertedTexts, ["Rewritten."])
    let entryFetched = try await fixture.store.recent().first
    let entry = try XCTUnwrap(entryFetched)
    XCTAssertEqual(entry.rewriteState, .succeeded)
    let attemptFetched = try await fixture.store.attempts(for: entry.id).first
    let attempt = try XCTUnwrap(attemptFetched)
    XCTAssertEqual(attempt.mode, .clean)
  }

  /// The rewritten text goes through the same insertion path, so a target that
  /// is gone lands in the existing `recovery` handling with both texts stored.
  func testLostTargetAfterARewriteKeepsBothTextsAndRecovers() async throws {
    let (coordinator, fixture) = try makeFixture(
      enabled: true, script: .succeed(text: "Rewritten."))
    fixture.insertion.outcome = .notInserted(.focusChanged)
    try await dictate(coordinator)
    XCTAssertEqual(fixture.insertion.insertedTexts, ["Rewritten."])
    let entryFetched = try await fixture.store.recent().first
    let entry = try XCTUnwrap(entryFetched)
    XCTAssertEqual(entry.text, faithful)
    XCTAssertEqual(entry.recoveryState, .needsReview)
    XCTAssertEqual(entry.rewriteState, .succeeded)
    XCTAssertEqual(entry.deliveredSource, .rewrite)
    let attemptsFetched = try await fixture.store.attempts(for: entry.id)
    let attempt = try XCTUnwrap(attemptsFetched.first)
    XCTAssertEqual(attempt.inputText, faithful)
    XCTAssertEqual(attempt.outputText, "Rewritten.")
  }

  func testBlankAndDurationLimitedResultsNeverEnterRewriting() async throws {
    for text in ["", "   \n "] {
      let (coordinator, fixture) = try makeFixture(
        enabled: true, transcript: text, failOnAnyCall: true)
      var states: [DictationSession.State] = []
      coordinator.stateChanged = { states.append($0) }
      try await dictate(coordinator)
      XCTAssertEqual(fixture.rig.callCount, 0, "blank text is not eligible")
      XCTAssertFalse(states.contains(.rewriting))
    }
  }

  func testCommitPrecedesAdmissionWhichPrecedesTheTransport() async throws {
    let gate = Gate()
    let (coordinator, fixture) = try makeFixture(
      enabled: true, script: .after(gate, then: .succeed(text: "Rewritten.")))
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { coordinator.state == .rewriting }
    // The transport is already running, which means both earlier steps landed.
    await fixture.rig.transport.waitUntilCalled()
    let entryFetched = try await fixture.store.recent().first
    let entry = try XCTUnwrap(entryFetched, "the faithful transcript is committed first")
    let attemptsFetched = try await fixture.store.attempts(for: entry.id)
    let attempt = try XCTUnwrap(attemptsFetched.first, "the row exists before the reply")
    XCTAssertEqual(attempt.state, .pending)
    XCTAssertEqual(fixture.rig.transport.requests.first?.requestID, attempt.id)
    await gate.openGate()
    try await waitUntil { !coordinator.busy }
  }

  func testCancelDuringRewriteInsertsFaithfulAndKeepsRecordingComplete() async throws {
    let (coordinator, fixture) = try makeFixture(enabled: true, script: .hang)
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { coordinator.state == .rewriting }
    coordinator.cancel()
    try await waitUntil { !coordinator.busy }
    XCTAssertEqual(fixture.insertion.insertedTexts, [faithful])
    XCTAssertEqual(coordinator.rewriteNotice?.message, "Rewrite cancelled. Original text inserted.")
    let fetched = try await fixture.store.recent().first
    let entry = try XCTUnwrap(fetched)
    XCTAssertEqual(entry.text, faithful)
    let attempts = try await fixture.store.attempts(for: entry.id)
    XCTAssertEqual(attempts.first?.state, .cancelled)
    XCTAssertEqual(entry.quality, .complete)
    XCTAssertEqual(entry.deliveredSource, .faithful)
  }

  func testNewDictationLeavesOlderRewriteInHistoryWithoutInsertion() async throws {
    let gate = Gate()
    let (coordinator, fixture) = try makeFixture(
      enabled: true, script: .after(gate, then: .succeed(text: "Older rewrite.")))
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { coordinator.state == .rewriting }
    await fixture.rig.transport.waitUntilCalled()
    let fetched = try await fixture.store.recent().first
    let first = try XCTUnwrap(fetched)
    fixture.rig.transport.setDefault(.succeed(text: "Newer rewrite."))
    XCTAssertTrue(coordinator.canBegin)
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }
    await gate.openGate()
    try await waitUntil { fixture.rig.coordinator.pendingCount == 0 }
    XCTAssertEqual(fixture.insertion.insertedTexts, ["Newer rewrite."])
    let attempts = try await fixture.store.attempts(for: first.id)
    XCTAssertEqual(attempts.first?.state, .succeeded)
    XCTAssertEqual(attempts.first?.outputText, "Older rewrite.")
    XCTAssertEqual(attempts.first?.delivered, false)
  }

  func testFiveOverlappingDictationsRefuseThreeWithoutRowsOrWrongInsertion() async throws {
    let gate = Gate()
    let (coordinator, fixture) = try makeFixture(
      enabled: true, script: .after(gate, then: .succeed(text: "Late rewrite.")))
    for index in 0..<5 {
      coordinator.begin()
      try await waitUntil { coordinator.state == .recording }
      coordinator.release()
      if index < 2 {
        try await waitUntil { coordinator.state == .rewriting }
      } else {
        try await waitUntil { !coordinator.busy }
        XCTAssertEqual(
          coordinator.rewriteNotice?.message,
          "Two rewrites are still running. Original text inserted.")
        XCTAssertEqual(coordinator.rewriteNotice?.canRetry, true)
      }
    }
    let entries = try await fixture.store.recent()
    XCTAssertEqual(entries.count, 5)
    XCTAssertEqual(entries.filter { $0.rewriteState == .notRequested }.count, 3)
    XCTAssertEqual(fixture.insertion.insertedTexts, Array(repeating: faithful, count: 3))
    await gate.openGate()
    try await waitUntil { fixture.rig.coordinator.pendingCount == 0 }
    XCTAssertEqual(fixture.insertion.insertedTexts.count, 3)
    for entry in entries {
      let persisted = try await fixture.store.get(entry.id)
      XCTAssertEqual(persisted?.text, faithful)
      let attempts = try await fixture.store.attempts(for: entry.id)
      XCTAssertEqual(attempts.count, entry.rewriteState == .notRequested ? 0 : 1)
      XCTAssertTrue(
        attempts.allSatisfy { $0.transcriptionID == entry.id && $0.state == .succeeded })
    }
  }

  func testTwentySequentialDictationsKeepAttemptIdentityAndDelivery() async throws {
    let (coordinator, fixture) = try makeFixture(enabled: true)
    for index in 0..<20 {
      let text = "Rewrite number \(index)."
      fixture.rig.transport.setDefault(
        index.isMultiple(of: 3) ? .fail(.serverUnreachable) : .succeed(text: text))
      try await dictate(coordinator)
      XCTAssertEqual(
        fixture.insertion.insertedTexts.last, index.isMultiple(of: 3) ? faithful : text)
    }
    let entries = try await fixture.store.recent(limit: 50)
    XCTAssertEqual(entries.count, 20)
    for entry in entries {
      let persisted = try await fixture.store.get(entry.id)
      XCTAssertEqual(persisted?.text, faithful)
      let attempts = try await fixture.store.attempts(for: entry.id)
      XCTAssertEqual(attempts.count, 1)
      let attempt = try XCTUnwrap(attempts.first)
      XCTAssertEqual(attempt.transcriptionID, entry.id)
      XCTAssertEqual(attempt.ordinal, 1)
      let request = fixture.rig.transport.requests.first { $0.requestID == attempt.id }
      XCTAssertEqual(request?.text, entry.text)
      XCTAssertEqual(
        entry.deliveredRewriteAttemptID, attempt.state == .succeeded ? attempt.id : nil)
    }
  }

  // MARK: Fixture

  private struct Fixture {
    let store: TranscriptionStore
    let insertion: FakeInsertion
    let rig: RewriteRig
  }

  // MARK: US6 (T053): a bypassed session stays on the Mac.

  func testBypassedSessionSkipsRewritingWithoutRowNoticeOrMetric() async throws {
    let (coordinator, fixture) = try makeFixture(enabled: true, failOnAnyCall: true)
    var metrics: [RewriteMetric] = []
    fixture.rig.coordinator.metricRecorded = { metrics.append($0) }
    var states: [DictationSession.State] = []
    coordinator.stateChanged = { states.append($0) }
    var notices: [RewriteActionNotice?] = []
    coordinator.rewriteNoticeChanged = { notices.append($0) }
    try await dictate(coordinator, bypassRewrite: true)
    XCTAssertEqual(fixture.rig.callCount, 0)
    XCTAssertFalse(states.contains(.rewriting))
    XCTAssertEqual(fixture.insertion.insertedTexts, [faithful])
    XCTAssertTrue(notices.compactMap { $0 }.isEmpty)
    XCTAssertTrue(metrics.isEmpty, "a bypass is an eligibility outcome, not a refusal")
    let fetched = try await fixture.store.recent().first
    let entry = try XCTUnwrap(fetched)
    XCTAssertEqual(entry.rewriteState, .notRequested)
    XCTAssertEqual(entry.deliveredSource, .faithful)
    let attempts = try await fixture.store.attempts(for: entry.id)
    XCTAssertTrue(attempts.isEmpty)
  }

  func testBypassedDictationCanStillBeRewrittenFromHistory() async throws {
    let (coordinator, fixture) = try makeFixture(
      enabled: true, script: .succeed(text: "Rewritten."))
    try await dictate(coordinator, bypassRewrite: true)
    XCTAssertEqual(fixture.rig.callCount, 0)
    let fetched = try await fixture.store.recent().first
    let entry = try XCTUnwrap(fetched)
    let dispatchesBefore = fixture.insertion.dispatchCount
    let outcome = await fixture.rig.coordinator.retry(
      dictation: entry.id, faithfulText: entry.text, mode: .clean, origin: .history)
    guard case .rewritten(let text, let attempt) = outcome else {
      return XCTFail("expected a rewritten outcome, got \(outcome)")
    }
    XCTAssertEqual(text, "Rewritten.")
    XCTAssertEqual(attempt.ordinal, 1)
    XCTAssertEqual(attempt.inputText, entry.text, "the snapshot is transcriptions.text")
    XCTAssertEqual(fixture.insertion.dispatchCount, dispatchesBefore, "history never inserts")
    let attempts = try await fixture.store.attempts(for: entry.id)
    XCTAssertEqual(attempts.map(\.ordinal), [1])
    XCTAssertEqual(attempts.first?.state, .succeeded)
  }

  /// The bypass never leaks into the next dictation.
  func testBypassAppliesToOneDictationOnly() async throws {
    let (coordinator, fixture) = try makeFixture(
      enabled: true, script: .succeed(text: "Rewritten."))
    try await dictate(coordinator, bypassRewrite: true)
    XCTAssertEqual(fixture.rig.callCount, 0)
    try await dictate(coordinator)
    XCTAssertEqual(fixture.rig.callCount, 1)
    XCTAssertEqual(fixture.insertion.insertedTexts.last, "Rewritten.")
  }

  private func makeFixture(
    enabled: Bool = false,
    mode: RewriteMode = .clean,
    endpoint: String = "http://127.0.0.1:8080",
    quality: TranscriptionEntry.Quality = .complete,
    transcript: String? = nil,
    script: FakeRewriteTransport.Script = .succeed(text: "Rewritten."),
    failOnAnyCall: Bool = false
  ) throws -> (DictationCoordinator, Fixture) {
    let store = try makeStore()
    let insertion = FakeInsertion(store: store)
    let rig = RewriteRig(
      store: store, enabled: enabled, mode: mode, endpoint: endpoint, script: script,
      failOnAnyCall: failOnAnyCall)
    rigs.append(rig)
    let spoolRoot = try makeSpoolRoot()
    ownedDirectories.append(spoolRoot)
    let runtime = FakeRuntime(text: transcript ?? faithful)
    let coordinator = DictationCoordinator(
      store: store, lifecycle: ModelLifecycleCoordinator { runtime }, capture: FakeCapture(),
      insertion: insertion, spoolRoot: spoolRoot, mailbox: ControlMailbox(),
      transcriber: quality == .complete
        ? nil
        : FakeDictationTranscriber(
          result: TranscriptionResult(
            text: faithful, incomplete: true, completionReasons: [.init(.failed)])),
      vocabulary: nil, rewriter: rig.coordinator)
    return (coordinator, Fixture(store: store, insertion: insertion, rig: rig))
  }

  private func dictate(_ coordinator: DictationCoordinator, bypassRewrite: Bool = false)
    async throws
  {
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release(bypassRewrite: bypassRewrite)
    try await waitUntil { !coordinator.busy }
  }

  private func makeStore() throws -> TranscriptionStore {
    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("LocalFlowStore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    ownedDirectories.append(directory)
    return try TranscriptionStore(path: directory.appendingPathComponent("history.sqlite").path)
  }

  private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !predicate() {
      guard clock.now < deadline else {
        XCTFail("timed out")
        throw TestTimeout.expired
      }
      await Task.yield()
    }
  }
}
