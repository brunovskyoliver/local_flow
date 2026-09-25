import XCTest

@testable import LocalFlow

final class WindowedTranscriptionTests: XCTestCase {
  func testProductionUsesContiguousWindowsAndKeepsExactRawText() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let spool = try AudioSpool(rootDirectory: root)
    defer { try? spool.cleanup() }
    for _ in 0..<160 { try spool.append(normalizedSamples: Array(repeating: 0.25, count: 1_600)) }
    let runtime = PipelineWindowRuntime()
    let lifecycle = ModelLifecycleCoordinator { runtime }
    let lease = try await lifecycle.acquire(session: UUID())
    let result = await WindowedTranscriber(lifecycle: lifecycle).transcribe(
      spool: spool, lease: lease, sampleCount: 256_000)
    await lifecycle.cancelAndJoin(lease)
    let counts = await runtime.counts
    XCTAssertEqual(counts, [239_360, 16_640])
    XCTAssertEqual(result.text, " c\u{030C}au , svet  svet znova ")
    XCTAssertFalse(result.incomplete)
    let detail = try XCTUnwrap(result.detail)
    XCTAssertEqual(detail.rawWindows.map(\.sampleStart), [0, 239_360])
    XCTAssertEqual(detail.rawWindows.map(\.text), [" c\u{030C}au , svet ", " svet znova "])
    XCTAssertEqual(detail.provenance.overlapSamples, 0)
    XCTAssertEqual(detail.provenance.strideSamples, 239_360)
    XCTAssertEqual(detail.vocabularyHash, TranscriptionQualityDetail.emptyVocabularyHash)
    XCTAssertEqual(detail.vocabularyRevision, 0)
    XCTAssertNotNil(detail.provenance.stageDurations["recognition"])
    XCTAssertNotNil(detail.provenance.stageDurations["assembly"])
    XCTAssertNoThrow(try detail.validate(normalizedText: result.text))
  }

  func testProductionNearDurationLimitHasExactCoverageAndNoDiscardedWords() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let spool = try AudioSpool(rootDirectory: root)
    defer { try? spool.cleanup() }
    for _ in 0..<1_800 { try spool.append(normalizedSamples: Array(repeating: 0, count: 1_600)) }
    let lifecycle = ModelLifecycleCoordinator { FakeRuntime(text: "repeat") }
    let lease = try await lifecycle.acquire(session: UUID())
    let result = await WindowedTranscriber(lifecycle: lifecycle).transcribe(
      spool: spool, lease: lease, sampleCount: 2_880_000)
    await lifecycle.cancelAndJoin(lease)
    let detail = try XCTUnwrap(result.detail)
    XCTAssertEqual(detail.rawWindows.count, 13)
    XCTAssertEqual(detail.rawWindows.reduce(0) { $0 + $1.sampleCount }, 2_880_000)
    XCTAssertEqual(detail.rawWindows.last?.sampleStart, 12 * 239_360)
    XCTAssertEqual(detail.rawWindows.last?.sampleCount, 7_680)
    XCTAssertEqual(detail.seams.count, 12)
    XCTAssertTrue(
      detail.seams.allSatisfy { $0.discardedLexicalWords == 0 && $0.discardedPrefixBytes == 0 })
    XCTAssertEqual(result.text.split(separator: " ").count, 13)
    XCTAssertFalse(result.incomplete)
  }

  func testProductionMetadataOverflowRetainsWholePriorEnvelope() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let spool = try AudioSpool(rootDirectory: root)
    defer { try? spool.cleanup() }
    for _ in 0..<160 { try spool.append(normalizedSamples: Array(repeating: 0, count: 1_600)) }
    let raw = String(repeating: "\u{0001}", count: 10_000)
    let lifecycle = ModelLifecycleCoordinator { FakeRuntime(text: raw) }
    let lease = try await lifecycle.acquire(session: UUID())
    let result = await WindowedTranscriber(lifecycle: lifecycle).transcribe(
      spool: spool, lease: lease, sampleCount: 256_000)
    await lifecycle.cancelAndJoin(lease)
    let detail = try XCTUnwrap(result.detail)
    XCTAssertEqual(detail.rawWindows.count, 1)
    XCTAssertEqual(detail.rawWindows.first?.text, raw)
    XCTAssertEqual(result.text, raw)
    XCTAssertTrue(result.incomplete)
    XCTAssertTrue(detail.completionReasons.contains { $0.code == .metadataCapacity })
    let normalized = result.normalizedForDelivery()
    let normalizedDetail = try XCTUnwrap(normalized.detail)
    XCTAssertEqual(normalizedDetail.rawWindows.first?.text, raw)
    XCTAssertTrue(normalized.incomplete)
    XCTAssertNoThrow(try normalizedDetail.validate(normalizedText: normalized.text))
  }

  func testProductionFinalWindowFailureStillHasFullDetail() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let spool = try AudioSpool(rootDirectory: root)
    defer { try? spool.cleanup() }
    for _ in 0..<160 { try spool.append(normalizedSamples: Array(repeating: 0, count: 1_600)) }
    let lifecycle = ModelLifecycleCoordinator { FailingSecondWindowRuntime() }
    let lease = try await lifecycle.acquire(session: UUID())
    let result = await WindowedTranscriber(lifecycle: lifecycle).transcribe(
      spool: spool, lease: lease, sampleCount: 256_000)
    await lifecycle.cancelAndJoin(lease)
    let detail = try XCTUnwrap(result.normalizedForDelivery().detail)
    XCTAssertEqual(detail.rawWindows.map(\.text), ["retained prefix"])
    XCTAssertEqual(detail.assembledText, "retained prefix")
    XCTAssertTrue(detail.incomplete)
  }

  /// Windows recognized while recording replay into the same windows, order and
  /// assembly as recognizing everything after stop, and are never recognized twice.
  func testIncrementalWindowsMatchTheBatchTranscript() async throws {
    let window = WindowedTranscriber.productionWindowSamples
    let total = 2 * window + 50_000
    func fill(_ spool: AudioSpool, from start: Int, to end: Int) throws {
      var offset = start
      while offset < end {
        let count = min(1_600, end - offset)
        // Each window carries its own level, so its text depends on its audio.
        try spool.append(
          normalizedSamples: (offset..<offset + count).map { Float($0 / window + 1) / 10 })
        offset += count
      }
    }
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let batchRuntime = ContentWindowRuntime()
    let batchLifecycle = ModelLifecycleCoordinator { batchRuntime }
    let batchSpool = try AudioSpool(rootDirectory: root)
    try fill(batchSpool, from: 0, to: total)
    let batchLease = try await batchLifecycle.acquire(session: UUID())
    let batch = await WindowedTranscriber(lifecycle: batchLifecycle).transcribe(
      spool: batchSpool, lease: batchLease, sampleCount: total)
    try await batchLifecycle.finish(batchLease)
    try batchSpool.cleanup()

    let liveRuntime = ContentWindowRuntime()
    let liveLifecycle = ModelLifecycleCoordinator { liveRuntime }
    let transcriber = WindowedTranscriber(lifecycle: liveLifecycle)
    XCTAssertEqual(transcriber.liveWindowSamples, window)
    let liveSpool = try AudioSpool(rootDirectory: root)
    defer { try? liveSpool.cleanup() }
    let liveLease = try await liveLifecycle.acquire(session: UUID())
    var prefetched: [Int: PrefetchedWindow] = [:]
    // Recording continues after each full window is recognized.
    try fill(liveSpool, from: 0, to: window + 10_000)
    prefetched[0] = try await transcriber.recognizeWindow(
      spool: liveSpool, lease: liveLease, startSample: 0)
    try fill(liveSpool, from: window + 10_000, to: 2 * window)
    prefetched[window] = try await transcriber.recognizeWindow(
      spool: liveSpool, lease: liveLease, startSample: window)
    try fill(liveSpool, from: 2 * window, to: total)
    let live = await transcriber.transcribe(
      spool: liveSpool, lease: liveLease, sampleCount: total, prefetched: prefetched)
    try await liveLifecycle.finish(liveLease)

    XCTAssertEqual(Array(live.text.utf8), Array(batch.text.utf8))
    XCTAssertEqual(live.incomplete, batch.incomplete)
    XCTAssertEqual(live.completionReasons, batch.completionReasons)
    let liveDetail = try XCTUnwrap(live.detail)
    let batchDetail = try XCTUnwrap(batch.detail)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    XCTAssertEqual(
      try encoder.encode(liveDetail.rawWindows), try encoder.encode(batchDetail.rawWindows))
    XCTAssertEqual(liveDetail.rawWindows.map(\.sampleStart), [0, window, 2 * window])
    XCTAssertEqual(Array(liveDetail.assembledText.utf8), Array(batchDetail.assembledText.utf8))
    XCTAssertEqual(liveDetail.seams, batchDetail.seams)
    XCTAssertEqual(
      Array(live.normalizedForDelivery().text.utf8),
      Array(batch.normalizedForDelivery().text.utf8))
    let liveCounts = await liveRuntime.counts
    let batchCounts = await batchRuntime.counts
    XCTAssertEqual(liveCounts, batchCounts, "no window may be recognized twice")
    XCTAssertEqual(liveCounts, [window, window, 50_000])
  }

  func testBundledPipelineIdentityIsBoundedAndUnknownBuildStateIsExplicit() throws {
    let url = try XCTUnwrap(Bundle.main.url(forResource: "parakeet-v3", withExtension: "json"))
    let data = try Data(contentsOf: url)
    let descriptor = try JSONDecoder().decode(ModelDescriptor.self, from: data)
    let identity = try TranscriptionPipelineIdentity(
      descriptor: descriptor,
      manifestHash: TranscriptionQualityDetail.hash(data), build: "test-build")
    let provenance = identity.provenance(sampleCount: 16_000, recognition: 1, assembly: 0.01)
    XCTAssertEqual(provenance.modelRevision, descriptor.sourceRevision)
    XCTAssertEqual(provenance.artifactHashes.count, descriptor.files.count)
    XCTAssertNil(provenance.dirty)
    XCTAssertTrue(
      provenance.unavailableMetadata.contains { $0.field == "dirty" && $0.reason == .notRecorded })
    XCTAssertThrowsError(
      try TranscriptionPipelineIdentity(
        descriptor: descriptor,
        manifestHash: "invalid", build: "test-build"))
    // Dictation runs Parakeet with the English/Slovak Latin-script filter, and the
    // provenance says so instead of "automatic; no hint".
    let filtered = try TranscriptionPipelineIdentity(
      descriptor: descriptor, manifestHash: TranscriptionQualityDetail.hash(data),
      build: "test-build", languageHint: FluidAudioRuntime.languageHint
    ).provenance(sampleCount: 16_000, recognition: 1, assembly: 0.01)
    XCTAssertNoThrow(try filtered.validate())
    XCTAssertEqual(filtered.languageHint, "en_sk_latin_script")
    XCTAssertFalse(filtered.automaticLanguage)
    XCTAssertEqual(FluidAudioRuntime.scriptFilter.script, .latin)
  }

  func testSmallTailPaddingPreservesAudioAndRejectsInvalidWindows() throws {
    let padded = try FluidAudioRuntime.paddedWindow([0.25, -0.5])
    XCTAssertEqual(padded.count, 4_800)
    XCTAssertEqual(Array(padded.prefix(2)), [0.25, -0.5])
    XCTAssertTrue(padded.dropFirst(2).allSatisfy { $0 == 0 })
    XCTAssertThrowsError(try FluidAudioRuntime.paddedWindow([]))
    XCTAssertThrowsError(try FluidAudioRuntime.paddedWindow([.nan]))
    XCTAssertThrowsError(try FluidAudioRuntime.paddedWindow(Array(repeating: 0, count: 239_361)))
  }

  func testTailTimestampsClampToRealAudioInsteadOfPadding() throws {
    let token = try FluidAudioRuntime.clampedToken(
      text: "fixture", start: -0.01, end: 0.3, sampleCount: 160)
    XCTAssertEqual(token.start, 0)
    XCTAssertEqual(token.end, 0.01)
    XCTAssertThrowsError(
      try FluidAudioRuntime.clampedToken(text: "bad", start: .nan, end: 0.3, sampleCount: 160))
    XCTAssertThrowsError(
      try FluidAudioRuntime.clampedToken(text: "bad", start: 0.2, end: 0.1, sampleCount: 160))
  }

  func testInvalidTokensLeavePreviouslyAcceptedTextUntouched() throws {
    for window in [
      TranscriptionWindow(text: "bad", tokens: [.init(text: "bad", start: .nan, end: 1)]),
      TranscriptionWindow(text: "bad", tokens: [.init(text: "bad", start: 2, end: 1)]),
      TranscriptionWindow(
        text: "bad", tokens: Array(repeating: .init(text: "a", start: 0, end: 1), count: 16_385)),
      TranscriptionWindow(
        text: "bad", tokens: [.init(text: String(repeating: "a", count: 65_537), start: 0, end: 1)]),
    ] {
      var assembler = WindowTextAssembler()
      try assembler.append(.init(text: "prefix", tokens: []), offset: 0)
      XCTAssertThrowsError(try assembler.append(window, offset: 12.96))
      XCTAssertEqual(assembler.text, "prefix")
    }
  }

  func testCumulativeTextLimitPreservesPrefix() throws {
    var assembler = WindowTextAssembler()
    let prefix = String(repeating: "a", count: 65_530)
    try assembler.append(.init(text: prefix, tokens: []), offset: 0)
    XCTAssertThrowsError(try assembler.append(.init(text: "too long", tokens: []), offset: 12.96))
    XCTAssertEqual(assembler.text, prefix)
  }

  func testFailedLaterWindowKeepsValidPrefix() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let spool = try AudioSpool(rootDirectory: root)
    defer { try? spool.cleanup() }
    for _ in 0..<160 { try spool.append(normalizedSamples: Array(repeating: 0, count: 1_600)) }
    let lifecycle = ModelLifecycleCoordinator { FailingSecondWindowRuntime() }
    let lease = try await lifecycle.acquire(session: UUID())
    let result = await WindowedTranscriber(lifecycle: lifecycle).transcribe(
      spool: spool, lease: lease, sampleCount: 256_000)
    XCTAssertEqual(result.text, "retained prefix")
    XCTAssertTrue(result.incomplete)
    XCTAssertEqual(result.rawWindows.map(\.text), ["retained prefix"])
    XCTAssertFalse(result.completionReasons.isEmpty)
    await lifecycle.cancelAndJoin(lease)
  }

  func testWholeWindowAdmissionPreservesExactPrefixOnRawAndMetadataOverflow() throws {
    var admission = RecognitionAdmission()
    let prefix = String(repeating: "x", count: 65_530)
    try admission.append(.init(text: prefix, tokens: []), sampleStart: 0, sampleCount: 239_360)
    XCTAssertThrowsError(
      try admission.append(
        .init(text: "overflow", tokens: []), sampleStart: 207_360, sampleCount: 16_000))
    XCTAssertEqual(admission.windows.count, 1)
    XCTAssertEqual(Array(admission.windows[0].text.utf8), Array(prefix.utf8))
    var metadata = RecognitionAdmission()
    try metadata.append(.init(text: "prefix", tokens: []), sampleStart: 0, sampleCount: 239_360)
    let evidence = RecognitionEvidence(
      text: "next", samples: 16_000, paddedSamples: 16_000,
      timingsAvailable: true,
      tokens: Array(repeating: .init(text: "x", start: .init(0), end: .init(0)), count: 4_000))
    XCTAssertThrowsError(
      try metadata.append(
        .init(text: "next", tokens: [], evidence: evidence), sampleStart: 207_360,
        sampleCount: 16_000))
    XCTAssertEqual(metadata.windows.count, 1)
  }

  func testAdmissionKeepsOriginalTimingsBeforeClamping() throws {
    var admission = RecognitionAdmission()
    let evidence = RecognitionEvidence(
      text: "raw", samples: 160, paddedSamples: 4_800,
      timingsAvailable: true, tokens: [.init(text: "raw", start: .init(-0.01), end: .init(0.3))])
    try admission.append(
      .init(text: "raw", tokens: [.init(text: "raw", start: 0, end: 0.01)], evidence: evidence),
      sampleStart: 0, sampleCount: 160)
    XCTAssertEqual(admission.windows.first?.timings?.first?.start.seconds, -0.01)
    XCTAssertEqual(admission.windows.first?.timings?.first?.end.seconds, 0.3)
    XCTAssertEqual(admission.windows.first?.timingValidation, .invalid)
  }

  func testAdmissionWindowLimitAndTokenTextBounds() throws {
    var admission = RecognitionAdmission()
    for index in 0..<14 {
      try admission.append(
        .init(text: "x", tokens: []), sampleStart: index * 207_360, sampleCount: 160)
    }
    XCTAssertThrowsError(
      try admission.append(.init(text: "x", tokens: []), sampleStart: 2_880_000, sampleCount: 160))
    XCTAssertEqual(admission.windows.count, 14)
    var tokens = RecognitionAdmission()
    XCTAssertThrowsError(
      try tokens.append(
        .init(
          text: "x", tokens: [.init(text: String(repeating: "x", count: 65_537), start: 0, end: 1)]),
        sampleStart: 0, sampleCount: 16_000))
    XCTAssertTrue(tokens.windows.isEmpty)
  }

  func testTimestampAnchorPreservesRepeatedWords() throws {
    var assembler = WindowTextAssembler()
    try assembler.append(
      TranscriptionWindow(
        text: "go go",
        tokens: [
          .init(text: "go", start: 12, end: 12.3), .init(text: "go", start: 13, end: 13.3),
        ]), offset: 0)
    try assembler.append(
      TranscriptionWindow(
        text: "go home",
        tokens: [
          .init(text: "go", start: 0.04, end: 0.34), .init(text: "home", start: 1, end: 1.3),
        ]), offset: 12.96)
    XCTAssertEqual(assembler.text, "go go home")
    XCTAssertFalse(assembler.incomplete)
  }
  func testUncertainSeamRequiresReview() throws {
    var assembler = WindowTextAssembler()
    try assembler.append(
      .init(text: "hello", tokens: [.init(text: "hello", start: 0, end: 1)]), offset: 0)
    try assembler.append(
      .init(text: "svet", tokens: [.init(text: "svet", start: 0, end: 1)]), offset: 12.96)
    XCTAssertTrue(assembler.incomplete)
    XCTAssertEqual(assembler.text, "hello svet")
  }
  func testTextLimitKeepsValidPrefix() throws {
    var assembler = WindowTextAssembler()
    try assembler.append(.init(text: "saved", tokens: []), offset: 0)
    XCTAssertThrowsError(
      try assembler.append(
        .init(text: String(repeating: "x", count: 65_537), tokens: []), offset: 12.96))
    XCTAssertEqual(assembler.text, "saved")
  }
}

private actor FailingSecondWindowRuntime: TranscriptionRuntime {
  private var calls = 0
  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    calls += 1
    if calls > 1 { throw DictationFailure.invalidResult }
    return .init(text: "retained prefix", tokens: [])
  }
  func shutdown() async {}
}

private actor PipelineWindowRuntime: TranscriptionRuntime {
  private(set) var counts: [Int] = []
  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    counts.append(samples.count)
    return .init(text: counts.count == 1 ? " c\u{030C}au , svet " : " svet znova ", tokens: [])
  }
  func shutdown() async {}
}

/// Text depends on the window's audio, so a misplaced window changes the transcript.
private actor ContentWindowRuntime: TranscriptionRuntime {
  private(set) var counts: [Int] = []
  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    counts.append(samples.count)
    let level = Int((samples.first ?? 0) * 10)
    return .init(text: " okno \(level) , dĺžka \(samples.count) ", tokens: [])
  }
  func shutdown() async {}
}
