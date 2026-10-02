import XCTest

@testable import LocalFlow
@testable import LocalFlowCore
@testable import LocalFlowSpeech

/// Feature 014 R1: the production window loop takes its windows from a source. Local
/// recognition and windows that came back from the server run the same assembly,
/// admission, boost hints, normalization and spellings.
final class WindowSourceTests: XCTestCase {
  private let window = WindowedTranscriber.productionWindowSamples

  func testWindowsAreContiguousFromSampleZero() async throws {
    let lifecycle = ModelLifecycleCoordinator { FakeRuntime() }
    let transcriber = WindowedTranscriber(lifecycle: lifecycle)
    let cases: [(Int, [WindowRequest])] = [
      (1, [.init(start: 0, count: 1)]),
      (239_360, [.init(start: 0, count: 239_360)]),
      (239_361, [.init(start: 0, count: 239_360), .init(start: 239_360, count: 1)]),
      (
        2_880_000,
        (0..<12).map { .init(start: $0 * 239_360, count: 239_360) }
          + [.init(start: 12 * 239_360, count: 7_680)]
      ),
    ]
    for (samples, expected) in cases {
      let requests = RequestLog()
      _ = await transcriber.transcribe(sampleCount: samples) { start, count in
        await requests.append(.init(start: start, count: count))
        return PrefetchedWindow(
          window: TranscriptionWindow(text: "w", tokens: []), recognitionSeconds: 0)
      }
      let seen = await requests.items
      XCTAssertEqual(seen, expected, "\(samples) samples")
    }
  }

  func testALoneYeahInAShortTailWindowIsDropped() async throws {
    let transcriber = WindowedTranscriber(lifecycle: ModelLifecycleCoordinator { FakeRuntime() })
    func run(_ samples: Int, tail: String) async -> TranscriptionResult {
      await transcriber.transcribe(sampleCount: samples) { start, _ in
        PrefetchedWindow(
          window: TranscriptionWindow(text: start == 0 ? "Is it done?" : tail, tokens: []),
          recognitionSeconds: 0)
      }
    }
    let dropped = await run(window + 8_000, tail: "Yeah.")
    XCTAssertEqual(dropped.text, "Is it done?")
    XCTAssertFalse(dropped.incomplete)
    XCTAssertEqual(dropped.rawWindows.last?.text, "Yeah.", "the raw window stays as evidence")
    let words = await run(window + 8_000, tail: "Right.")
    XCTAssertEqual(words.text, "Is it done? Right.")
    let long = await run(window + 64_000, tail: "Yeah.")
    XCTAssertEqual(long.text, "Is it done? Yeah.")
    let alone = await transcriber.transcribe(sampleCount: 8_000) { _, _ in
      PrefetchedWindow(
        window: TranscriptionWindow(text: "Yeah.", tokens: []), recognitionSeconds: 0)
    }
    XCTAssertEqual(alone.text, "Yeah.", "a first window is never dropped")
  }

  func testRemoteShapedSourceGivesTheLocalResult() async throws {
    let entries = [
      VocabularyEntry(id: "z", canonical: "Zabbix"),
      VocabularyEntry(id: "k", canonical: "Keycloak", aliases: ["key cloak"]),
    ]
    let vocabulary = try VocabularySnapshot(
      revision: 1, hash: TranscriptionQualityDetail.hash(VocabularyValidation.serialize(entries)),
      entries: entries)
    for samples in [1, 239_360, 239_361, 2 * window + 50_000] {
      let root = try makeSpoolRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let spool = try AudioSpool(rootDirectory: root)
      defer { try? spool.cleanup() }
      var written = 0
      while written < samples {
        let count = min(1_600, samples - written)
        try spool.append(
          normalizedSamples: (written..<written + count).map { Float($0 / window + 1) / 10 })
        written += count
      }
      let runtime = EvidenceWindowRuntime()
      let lifecycle = ModelLifecycleCoordinator { runtime }
      let lease = try await lifecycle.acquire(
        session: UUID(), boost: VocabularyBoostTerms(snapshot: vocabulary))
      let local = await WindowedTranscriber(lifecycle: lifecycle).transcribe(
        spool: spool, lease: lease, sampleCount: samples)
      await lifecycle.cancelAndJoin(lease)
      let produced = await runtime.produced

      // The same windows, delivered as the server would: keyed by sample start.
      let byStart = Dictionary(
        uniqueKeysWithValues: produced.enumerated().map { ($0.offset * window, $0.element) })
      let remote = await WindowedTranscriber(lifecycle: lifecycle).transcribe(
        sampleCount: samples
      ) { start, _ in
        guard let found = byStart[start] else { throw DictationFailure.invalidResult }
        return PrefetchedWindow(window: found, recognitionSeconds: 0.01)
      }
      try assertSameResult(local, remote, vocabulary: vocabulary, "\(samples) samples")
    }
  }

  func testInvalidSourceWindowIsRejectedTheSameWay() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let spool = try AudioSpool(rootDirectory: root)
    defer { try? spool.cleanup() }
    for _ in 0..<160 { try spool.append(normalizedSamples: Array(repeating: 0.1, count: 1_600)) }
    let lifecycle = ModelLifecycleCoordinator { MismatchedEvidenceRuntime() }
    let lease = try await lifecycle.acquire(session: UUID())
    let local = await WindowedTranscriber(lifecycle: lifecycle).transcribe(
      spool: spool, lease: lease, sampleCount: 256_000)
    await lifecycle.cancelAndJoin(lease)
    let remote = await WindowedTranscriber(lifecycle: lifecycle).transcribe(
      sampleCount: 256_000
    ) { _, count in
      PrefetchedWindow(
        window: MismatchedEvidenceRuntime.window(samples: count), recognitionSeconds: 0)
    }
    XCTAssertTrue(local.incomplete)
    XCTAssertEqual(local.completionReasons, remote.completionReasons)
    XCTAssertTrue(remote.completionReasons.contains { $0.code == .invalidResult })
    XCTAssertEqual(local.text, remote.text)
    XCTAssertEqual(local.rawWindows.count, remote.rawWindows.count)
  }

  private func assertSameResult(
    _ local: TranscriptionResult, _ remote: TranscriptionResult,
    vocabulary: VocabularySnapshot, _ message: String
  ) throws {
    XCTAssertEqual(local.text, remote.text, message)
    XCTAssertEqual(local.incomplete, remote.incomplete, message)
    XCTAssertEqual(local.completionReasons, remote.completionReasons, message)
    XCTAssertEqual(local.boostHints, remote.boostHints, message)
    XCTAssertFalse(local.boostHints.isEmpty, message)
    let localDetail = try XCTUnwrap(local.detail, message)
    let remoteDetail = try XCTUnwrap(remote.detail, message)
    XCTAssertEqual(try canonical(localDetail), try canonical(remoteDetail), message)
    let localDelivered = local.normalizedForDelivery(vocabulary: vocabulary)
    let remoteDelivered = remote.normalizedForDelivery(vocabulary: vocabulary)
    XCTAssertEqual(localDelivered.text, remoteDelivered.text, message)
    XCTAssertTrue(localDelivered.text.contains("Zabbix"), message)
    XCTAssertTrue(localDelivered.text.contains("Keycloak"), message)
    XCTAssertEqual(
      localDelivered.detail?.appliedRuleIDs, remoteDelivered.detail?.appliedRuleIDs, message)
    XCTAssertEqual(
      localDelivered.detail?.appliedEntryIDs, remoteDelivered.detail?.appliedEntryIDs, message)
    let terms = [ContextTerm(text: "Alerts", source: .windowTitle, kind: .name)]
    let localSpelled = ContextSpeller.apply(
      to: localDelivered.text, terms: terms, dictionaryTerms: ["Zabbix"])
    let remoteSpelled = ContextSpeller.apply(
      to: remoteDelivered.text, terms: terms, dictionaryTerms: ["Zabbix"])
    XCTAssertEqual(localSpelled.text, remoteSpelled.text, message)
  }

  /// The detail minus measured durations and the hash that covers them.
  private func canonical(_ detail: TranscriptionQualityDetail) throws -> String {
    func strip(_ value: Any) -> Any {
      if let object = value as? [String: Any] {
        return object.filter { !["stageDurations", "duration", "contentHash"].contains($0.key) }
          .mapValues(strip)
      }
      if let array = value as? [Any] { return array.map(strip) }
      return value
    }
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(detail))
    let data = try JSONSerialization.data(withJSONObject: strip(object), options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }
}

private struct WindowRequest: Equatable, Sendable {
  let start: Int
  let count: Int
}

private actor RequestLog {
  private(set) var items: [WindowRequest] = []
  func append(_ item: WindowRequest) { items.append(item) }
}

/// Each window's text depends on its audio level; every window carries timed evidence
/// and a spotter hint, like the FluidAudio runtime with the keyword spotter installed.
private actor EvidenceWindowRuntime: TranscriptionRuntime {
  private(set) var produced: [TranscriptionWindow] = []

  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    try await transcribe(samples, boost: nil)
  }

  func transcribe(_ samples: [Float], boost: VocabularyBoostTerms?) async throws
    -> TranscriptionWindow
  {
    let level = Int(((samples.first ?? 0) * 10).rounded())
    let words = ["zabix", "sends", "key", "cloak", "alert", "\(level)"]
    let text = words.joined(separator: " ")
    let duration = Double(samples.count) / 16_000
    let step = duration / Double(words.count)
    let tokens = words.enumerated().map { index, word in
      TranscriptionToken(
        text: word, start: Double(index) * step, end: Double(index) * step + step * 0.9)
    }
    let evidence = RecognitionEvidence(
      text: text, samples: samples.count, paddedSamples: max(4_800, samples.count),
      timingsAvailable: true,
      tokens: tokens.map { .init(text: $0.text, start: .init($0.start), end: .init($0.end)) })
    let hints =
      boost == nil ? [] : [VocabularyBoostHint(source: "zabix", canonical: "Zabbix", entryID: "z")]
    let window = TranscriptionWindow(
      text: text, tokens: tokens, evidence: evidence, boostHints: hints)
    produced.append(window)
    return window
  }

  func shutdown() async {}
}

/// Evidence whose sample count disagrees with the window: admission refuses it.
private struct MismatchedEvidenceRuntime: TranscriptionRuntime {
  static func window(samples: Int) -> TranscriptionWindow {
    TranscriptionWindow(
      text: "wrong", tokens: [],
      evidence: RecognitionEvidence(
        text: "wrong", samples: samples + 1, paddedSamples: max(4_800, samples + 1),
        timingsAvailable: false, tokens: []))
  }

  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    Self.window(samples: samples.count)
  }

  func shutdown() async {}
}
