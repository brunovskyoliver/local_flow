import XCTest

@testable import LocalFlow

final class TranscriptAssemblerTests: XCTestCase {
  func testLongMeetingWindowsHaveExplicitBoundsWithoutWideningDictation() {
    let first = TranscriptAssembler.Window(
      sequence: 0, sampleStart: 0, sampleCount: 1_920_000,
      paddedSampleCount: 1_920_000, text: "Prvá veta.", tokens: nil)
    let second = TranscriptAssembler.Window(
      sequence: 1, sampleStart: 1_920_000, sampleCount: 1_920_000,
      paddedSampleCount: 1_920_000, text: "Druhá veta.", tokens: nil)
    var dictation = TranscriptAssembler()
    dictation.append(first)
    XCTAssertTrue(dictation.reasons.contains(.invalidResult))
    var meeting = TranscriptAssembler(maximumWindowSamples: 1_920_000)
    meeting.append(first)
    meeting.append(second)
    XCTAssertFalse(meeting.incomplete)
    XCTAssertTrue(meeting.text.contains("Prvá veta."))
    XCTAssertTrue(meeting.text.contains("Druhá veta."))
    var windows = MeetingWindowAssembler(
      geometry: MeetingFinalizer.Configuration.turbo.geometry, maximumWindowSamples: 1_920_000)
    _ = windows.append(window: first)
    XCTAssertEqual(windows.append(window: second).text, "Druhá veta.")
  }

  struct Corpus: Decodable {
    struct Case: Decodable {
      struct Expected: Decodable {
        let rawUtf8Hex: [String]
        let assembledText: String
        let assembledWords: [String]
        let incomplete: Bool
        let reasons: [String]
        let automaticInsertionAllowed: Bool
      }
      let id: String
      let windows: [TranscriptAssembler.Window]
      let expected: Expected
    }
    let cases: [Case]
  }

  func testAuthoritativeCorpusAndByteDeterminism() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let corpus = try QualityArtifacts.read(
      Corpus.self, from: root.appendingPathComponent("fixtures/quality/assembly-cases.json"))
    XCTAssertEqual(corpus.cases.count, 27)
    for fixture in corpus.cases {
      var first = TranscriptAssembler()
      var second = TranscriptAssembler()
      for window in fixture.windows {
        first.append(window)
        second.append(window)
      }
      XCTAssertEqual(Data(first.text.utf8), Data(fixture.expected.assembledText.utf8), fixture.id)
      XCTAssertEqual(
        first.text.split(whereSeparator: \.isWhitespace).map(String.init),
        fixture.expected.assembledWords, fixture.id)
      XCTAssertEqual(first.incomplete, fixture.expected.incomplete, fixture.id)
      XCTAssertEqual(first.reasons.map(\.rawValue), fixture.expected.reasons, fixture.id)
      XCTAssertEqual(!first.incomplete, fixture.expected.automaticInsertionAllowed, fixture.id)
      XCTAssertEqual(
        first.rawWindows.map { Data($0.text.utf8).map { String(format: "%02x", $0) }.joined() },
        fixture.expected.rawUtf8Hex, fixture.id)
      XCTAssertEqual(Data(first.text.utf8), Data(second.text.utf8), fixture.id)
      XCTAssertEqual(first.seams, second.seams, fixture.id)
      XCTAssertEqual(first.sourceSpans, second.sourceSpans, fixture.id)
      for span in first.sourceSpans {
        let raw = Array(first.rawWindows[span.rawWindowIndex].text.utf8)
        let output = Array(first.text.utf8)
        XCTAssertEqual(
          Array(raw[span.utf8Start..<span.utf8End]),
          Array(
            output[span.outputUTF8Start..<(span.outputUTF8Start + span.utf8End - span.utf8Start)]),
          fixture.id)
      }
    }
  }
}

extension TranscriptAssemblerTests {
  private func window(
    _ text: String, sequence: Int = 0, start: Int = 0,
    samples: Int = 239_360, tokens: [TranscriptAssembler.Token]? = nil
  ) -> TranscriptAssembler.Window {
    .init(
      sequence: sequence, sampleStart: start, sampleCount: samples,
      paddedSampleCount: max(4_800, samples), text: text, tokens: tokens)
  }

  func testRawWindowAndSessionExactByteLimitsRejectWholeWindow() {
    for size in [65_536, 65_537, 1_000_000] {
      var value = TranscriptAssembler()
      value.append(window(String(repeating: "x", count: size)))
      XCTAssertEqual(value.rawWindows.count, size == 65_536 ? 1 : 0)
      XCTAssertEqual(value.text.utf8.count, size == 65_536 ? size : 0)
      XCTAssertEqual(value.stopped, size != 65_536)
    }
    var value = TranscriptAssembler()
    value.append(window(String(repeating: "č", count: 32_768)))
    value.append(window("x", sequence: 1, start: 239_360))
    XCTAssertEqual(value.rawWindows.count, 1)
    XCTAssertEqual(value.text.utf8.count, 65_536)
    XCTAssertEqual(value.reasons, [.rawCapacity])
  }

  func testOutputCapacityIncludesSeparatorAndRetainsRaw() {
    for size in [65_534, 65_535] {
      var value = TranscriptAssembler()
      value.append(window(String(repeating: "x", count: size)))
      value.append(window("y", sequence: 1, start: 239_360))
      XCTAssertEqual(value.rawWindows.count, 2)
      XCTAssertEqual(value.text.utf8.count, size == 65_534 ? 65_536 : size)
      XCTAssertEqual(value.stopped, size == 65_535)
    }
  }

  func testWindowAndSeamSummaryLimitsDoNotGrow() {
    var value = TranscriptAssembler()
    for n in 0..<14 {
      value.append(
        window(
          "x", sequence: n, start: n * 207_360,
          samples: min(239_360, 2_880_000 - n * 207_360)))
    }
    XCTAssertEqual(value.rawWindows.count, 14)
    XCTAssertEqual(value.seams.count, 13)
    XCTAssertEqual(value.sourceSpans.count, 14)
    value.append(window("rejected", sequence: 14, start: 14 * 207_360))
    for _ in 0..<100 {
      value.append(window("rejected"))
      value.stop(.windowCapacity)
    }
    XCTAssertEqual(value.rawWindows.count, 14)
    XCTAssertEqual(value.seams.count, 13)
    XCTAssertEqual(value.reasons, [.uncertainJoin, .windowCapacity])
    // Closed typed codes cannot reach 64 distinct reasons or a 128-byte ID.
    let codes: [TranscriptAssembler.Reason] = [
      .uncertainJoin, .rawCapacity, .windowCapacity,
      .mappingCapacity, .overlapCapacity, .outputCapacity, .invalidResult, .cancelled, .failed,
    ]
    for code in codes {
      value.stop(code)
      XCTAssertLessThanOrEqual(code.rawValue.utf8.count, 128)
    }
    XCTAssertEqual(value.reasons.count, 9)
  }

  func testMappingAndTokenTextExactLimits() {
    for count in [16_384, 16_385] {
      var value = TranscriptAssembler()
      let tokens = (0..<count).map { index in
        TranscriptAssembler.Token(
          text: "x", utf8Start: index * 2, utf8End: index * 2 + 1,
          startSeconds: 0, endSeconds: 0)
      }
      value.append(window(String(repeating: "x ", count: count), tokens: tokens))
      XCTAssertEqual(value.rawWindows.count, count == 16_384 ? 1 : 0)
      XCTAssertEqual(value.stopped, count > 16_384)
    }
    for size in [65_536, 65_537] {
      var value = TranscriptAssembler()
      value.append(
        window(
          "raw",
          tokens: [
            .init(
              text: String(repeating: "x", count: size),
              utf8Start: 0, utf8End: size, startSeconds: 0, endSeconds: 0)
          ]))
      XCTAssertEqual(value.rawWindows.count, size == 65_536 ? 1 : 0)
    }
  }

  func testOverlapTokenAndByteLimits() {
    for count in [2_047, 2_048] {
      let text = Array(repeating: "x", count: count).joined(separator: " ")
      let tokens = (0..<count).map { index in
        TranscriptAssembler.Token(
          text: "x", utf8Start: index * 2, utf8End: index * 2 + 1,
          startSeconds: 13, endSeconds: 13.1)
      }
      var value = TranscriptAssembler()
      value.append(window(text, tokens: tokens))
      value.append(
        window(
          "x", sequence: 1, start: 207_360,
          tokens: [
            .init(text: "x", utf8Start: 0, utf8End: 1, startSeconds: 0.04, endSeconds: 0.14)
          ]))
      XCTAssertEqual(value.reasons, count == 2_047 ? [.uncertainJoin] : [.overlapCapacity])
      XCTAssertEqual(value.rawWindows.count, 2)
    }
    for size in [8_192, 8_193] {
      let text = String(repeating: "x", count: size)
      var value = TranscriptAssembler()
      value.append(
        window(
          text,
          tokens: [
            .init(
              text: text, utf8Start: 0, utf8End: size,
              startSeconds: 13, endSeconds: 13.1)
          ]))
      value.append(
        window(
          String(repeating: "x", count: 8_192), sequence: 1, start: 207_360,
          tokens: [
            .init(
              text: String(repeating: "x", count: 8_192), utf8Start: 0, utf8End: 8_192,
              startSeconds: 0.04, endSeconds: 0.14)
          ]))
      XCTAssertEqual(value.reasons, size == 8_192 ? [] : [.overlapCapacity])
      XCTAssertEqual(value.text.utf8.count, size)
    }
  }

  func testInvalidFloatsAndMappingsNeverDeleteText() {
    for time in [Double.nan, Double.infinity, -Double.infinity, -1, 30] {
      var value = TranscriptAssembler()
      value.append(
        window(
          "no",
          tokens: [
            .init(
              text: "no", utf8Start: 0, utf8End: 2,
              startSeconds: 13, endSeconds: 13.1)
          ]))
      value.append(
        window(
          "no", sequence: 1, start: 207_360,
          tokens: [
            .init(text: "no", utf8Start: 0, utf8End: 2, startSeconds: time, endSeconds: time)
          ]))
      XCTAssertEqual(value.text, "no no")
      XCTAssertEqual(value.reasons, [.uncertainJoin])
    }
    for range in [(-1, 2), (0, 20), (1, 2), (2, 0)] {
      var value = TranscriptAssembler()
      value.append(
        window(
          "č",
          tokens: [
            .init(
              text: "č", utf8Start: 0, utf8End: 2,
              startSeconds: 13, endSeconds: 13.1)
          ]))
      value.append(
        window(
          "č", sequence: 1, start: 207_360,
          tokens: [
            .init(
              text: "č", utf8Start: range.0, utf8End: range.1, startSeconds: 0.04, endSeconds: 0.14)
          ]))
      XCTAssertEqual(value.text, "č č")
      XCTAssertTrue(value.incomplete)
    }
  }

  func testCancellationAndFinalFailurePreserveCompletedWindow() {
    for reason: TranscriptAssembler.Reason in [.cancelled, .failed] {
      var value = TranscriptAssembler()
      value.append(window("Ďakujem, foo_bar v1.2 172.19.223.20!"))
      let raw = value.rawWindows[0].text
      value.stop(reason)
      value.append(window("must not be admitted", sequence: 1, start: 207_360))
      XCTAssertEqual(Data(value.text.utf8), Data(raw.utf8))
      XCTAssertEqual(value.rawWindows.count, 1)
      XCTAssertEqual(value.reasons, [reason])
    }
  }

  func testSourceMappingPreservesPunctuationWhitespaceAndBytes() {
    let text = "  č\tfoo_bar v1.2 172.19.223.20!\n"
    let words = ["č", "foo_bar", "v1.2", "172.19.223.20!"].map {
      TranscriptionToken(text: $0, start: 0, end: 1)
    }
    let mapped = TranscriptSourceMapper.map(text: text, words: words)
    XCTAssertEqual(mapped?.count, 4)
    for token in mapped ?? [] {
      XCTAssertEqual(Array(text.utf8)[token.utf8Start..<token.utf8End], ArraySlice(token.text.utf8))
    }
    XCTAssertNil(
      TranscriptSourceMapper.map(text: "hello!", words: [.init(text: "hello", start: 0, end: 1)]))
    XCTAssertNil(
      TranscriptSourceMapper.map(text: "foobar", words: [.init(text: "bar", start: 0, end: 1)]))
  }

  func testSourceMappingTracksMultibyteWhitespaceAndDecomposedWords() throws {
    let texts = ["e\u{0301}", "👩🏽‍💻", "日本語", "end!"]
    let text = "\u{2003}" + texts.joined(separator: "\r\n\u{00A0}\t") + "\n"
    let words = texts.map { TranscriptionToken(text: $0, start: 0, end: 1) }
    let mapped = try XCTUnwrap(TranscriptSourceMapper.map(text: text, words: words))
    let bytes = Array(text.utf8)
    var expectedStart = 3
    for (token, word) in zip(mapped, texts) {
      XCTAssertEqual(token.utf8Start, expectedStart)
      XCTAssertEqual(token.utf8End, expectedStart + word.utf8.count)
      XCTAssertTrue(bytes[token.utf8Start..<token.utf8End].elementsEqual(word.utf8))
      expectedStart = token.utf8End + 5
    }
    XCTAssertNil(
      TranscriptSourceMapper.map(text: "é", words: [.init(text: "e\u{0301}", start: 0, end: 1)]))
  }

  func testRepeatedWordsAtDistinctTimesInOverlapSurvive() {
    var value = TranscriptAssembler()
    value.append(
      window(
        "no",
        tokens: [
          .init(
            text: "no", utf8Start: 0, utf8End: 2,
            startSeconds: 13, endSeconds: 13.1)
        ]))
    value.append(
      window(
        "no no", sequence: 1, start: 207_360,
        tokens: [
          .init(text: "no", utf8Start: 0, utf8End: 2, startSeconds: 0.04, endSeconds: 0.14),
          .init(text: "no", utf8Start: 3, utf8End: 5, startSeconds: 0.7, endSeconds: 0.8),
        ]))
    XCTAssertEqual(value.text, "no no")
    XCTAssertFalse(value.incomplete)
  }
}

extension TranscriptAssemblerTests {
  func testOptInFrozenCorpusReplay() throws {
    let env = ProcessInfo.processInfo.environment
    guard let manifest = env["LOCALFLOW_ASSEMBLY_MANIFEST"],
      let baseline = env["LOCALFLOW_ASSEMBLY_BASELINE"],
      let output = env["LOCALFLOW_ASSEMBLY_OUTPUT"]
    else { throw XCTSkip("Set explicit frozen assembly replay inputs and new output directory.") }
    do {
      try QualityAssemblyReplay.run(
        manifestURL: URL(fileURLWithPath: manifest),
        baseline: URL(fileURLWithPath: baseline), output: URL(fileURLWithPath: output))
    } catch {
      XCTFail("assembly_replay_failed; inspect private inputs and ledger")
    }
  }

  func testInvalidOriginalSubwordTimingCannotBecomeValidWordEvidence() throws {
    let evidence = RecognitionEvidence(
      text: "hello", samples: 239_360, paddedSamples: 239_360,
      timingsAvailable: true,
      tokens: [
        .init(text: "▁he", start: .init(0), end: .init(.nan)),
        .init(text: "llo", start: .init(0.1), end: .init(0.2)),
      ])
    let raw = QualityResult.Window(
      sequence: 0, sampleStart: 0, evidence: evidence,
      text: evidence.text, sha256: QualityArtifacts.hash(Data(evidence.text.utf8)),
      tokens: evidence.tokens)
    let mapped = try QualityAssemblyReplay.mappedWindow(raw)
    XCTAssertNil(mapped.tokens)
    XCTAssertEqual(mapped.text, evidence.text)
  }
}

extension TranscriptAssemblerTests {
  func testStickyUncertaintyAndSpacing() {
    var value = TranscriptAssembler()
    value.append(window("  Ďakujem,\t"))
    value.append(window("\nno no  ", sequence: 1, start: 207_360))
    value.append(window("Next!", sequence: 2, start: 446_720))
    XCTAssertEqual(Data(value.text.utf8), Data("  Ďakujem,\t\nno no  Next!".utf8))
    XCTAssertEqual(value.reasons, [.uncertainJoin])
    XCTAssertEqual(value.seams.map(\.decision), ["uncertain_join", "adjacent"])
  }

  func testSampleAdmissionLimitsAndInvalidOffsetsPreservePrefix() {
    for count in [0, 239_361, Int.max] {
      var value = TranscriptAssembler()
      value.append(window("kept"))
      value.append(window("rejected", sequence: 1, start: 207_360, samples: count))
      XCTAssertEqual(value.text, "kept")
      XCTAssertEqual(value.rawWindows.count, 1)
      XCTAssertEqual(value.reasons, [.invalidResult])
    }
    for start in [-1, 2_880_000, Int.max] {
      var value = TranscriptAssembler()
      value.append(window("rejected", start: start))
      XCTAssertTrue(value.rawWindows.isEmpty)
      XCTAssertEqual(value.reasons, [.invalidResult])
    }
    for count in [1, 4_799, 4_800, 239_360] {
      var value = TranscriptAssembler()
      value.append(window("kept", samples: count))
      XCTAssertEqual(value.text, "kept")
      XCTAssertFalse(value.incomplete)
    }
  }

  func testTimingToleranceDoesNotExcuseDifferentOccurrences() {
    for drift in [0.16, 0.1601] {
      var value = TranscriptAssembler()
      value.append(
        window(
          "no",
          tokens: [
            .init(
              text: "no", utf8Start: 0, utf8End: 2,
              startSeconds: 12.96 + drift, endSeconds: 13.16 + drift)
          ]))
      value.append(
        window(
          "no", sequence: 1, start: 207_360,
          tokens: [
            .init(text: "no", utf8Start: 0, utf8End: 2, startSeconds: 0, endSeconds: 0.2)
          ]))
      XCTAssertEqual(value.text, drift == 0.16 ? "no" : "no no")
      XCTAssertEqual(value.incomplete, drift > 0.16)
    }
  }
}

extension TranscriptAssemblerTests {
  func testOptInLegacyAssemblyDiagnostic() throws {
    let env = ProcessInfo.processInfo.environment
    guard let manifest = env["LOCALFLOW_ASSEMBLY_MANIFEST"],
      let baseline = env["LOCALFLOW_ASSEMBLY_BASELINE"],
      let candidate = env["LOCALFLOW_ASSEMBLY_CANDIDATE"],
      let output = env["LOCALFLOW_ASSEMBLY_DIAGNOSTIC"]
    else { throw XCTSkip("Set explicit frozen inputs and a new diagnostic output directory.") }
    do {
      try QualityAssemblyReplay.diagnose(
        manifestURL: URL(fileURLWithPath: manifest), baseline: URL(fileURLWithPath: baseline),
        candidate: URL(fileURLWithPath: candidate), output: URL(fileURLWithPath: output))
    } catch {
      XCTFail("assembly_diagnostic_failed; inspect private inputs")
    }
  }
}

final class ChunkPlannerTests: XCTestCase {
  private func plan(_ planner: ChunkPlanner, samples: Int) async throws -> [ChunkPlanner.Chunk] {
    var chunks: [ChunkPlanner.Chunk] = []
    var previous: ChunkPlanner.Chunk?
    while let next = try await planner.next(after: previous, sampleCount: samples) {
      chunks.append(next)
      previous = next
      if chunks.count > 64 { break }
    }
    return chunks
  }

  func testFixedGeometryCoversTheDurationCapWithinFourteenWindows() async throws {
    for overlap in [32_000, ChunkPlanner.maximumSamples - ChunkPlanner.minimumStride] {
      let chunks = try await plan(ChunkPlanner(overlapSamples: overlap), samples: 2_880_000)
      XCTAssertLessThanOrEqual(chunks.count, 14)
      XCTAssertEqual(chunks.first?.sampleStart, 0)
      XCTAssertEqual(
        chunks.last.map { $0.sampleStart + $0.sampleCount }, 2_880_000)
      for (previous, next) in zip(chunks, chunks.dropFirst()) {
        XCTAssertEqual(next.sampleStart, previous.sampleStart + previous.sampleCount - overlap)
        XCTAssertLessThanOrEqual(previous.sampleCount, ChunkPlanner.maximumSamples)
      }
    }
    XCTAssertThrowsError(
      try ChunkPlanner(overlapSamples: ChunkPlanner.maximumSamples - ChunkPlanner.minimumStride + 1)
        .validate())
  }

  func testSilenceCutsAreContiguousAndFallBackDeterministically() async throws {
    let cut = 210_000
    var planner = ChunkPlanner(
      overlapSamples: 32_000, silenceSearchStart: ChunkPlanner.minimumStride)
    planner.silenceProbe = { start, _ in
      start == ChunkPlanner.minimumStride
        ? .init(sample: cut, speechProbability: 0.05) : nil
    }
    let chunks = try await plan(planner, samples: 700_000)
    XCTAssertEqual(chunks[0].boundary, "vad_selected")
    XCTAssertEqual(chunks[0].sampleCount, cut)
    // A silence cut is contiguous; the next chunk starts exactly where the previous one ended.
    XCTAssertEqual(chunks[1].sampleStart, cut)
    XCTAssertEqual(chunks[1].boundary, "nominal_fallback")
    XCTAssertEqual(chunks[2].sampleStart, cut + ChunkPlanner.maximumSamples - 32_000)
    XCTAssertEqual(chunks.last?.boundary, "final")
    XCTAssertEqual(chunks.last.map { $0.sampleStart + $0.sampleCount }, 700_000)
    var silent = planner
    silent.silenceProbe = { _, _ in nil }
    let fallback = try await plan(silent, samples: 700_000)
    XCTAssertEqual(
      fallback.map(\.boundary),
      ["nominal_fallback", "nominal_fallback", "nominal_fallback", "final"])
    XCTAssertEqual(fallback[1].sampleStart, ChunkPlanner.maximumSamples - 32_000)
  }

  /// The worst case for the fourteen-window cap is all-contiguous minimum-length chunks.
  func testSilenceOnlyGeometryStillFitsFourteenWindows() async throws {
    var planner = ChunkPlanner(
      overlapSamples: 0, silenceSearchStart: ChunkPlanner.minimumStride)
    // The earliest admissible cut is the worst case for the window budget.
    planner.silenceProbe = { start, _ in
      .init(sample: start + 1, speechProbability: 0.01)
    }
    let chunks = try await plan(planner, samples: 2_880_000)
    XCTAssertEqual(chunks.map(\.sequence), Array(0..<chunks.count))
    XCTAssertEqual(chunks.filter { $0.boundary == "vad_selected" }.count, chunks.count - 1)
    XCTAssertLessThanOrEqual(chunks.count, 14)
    XCTAssertEqual(chunks.map(\.sampleCount).reduce(0, +), 2_880_000)
    for (previous, next) in zip(chunks, chunks.dropFirst()) {
      XCTAssertEqual(next.sampleStart, previous.sampleStart + previous.sampleCount)
    }
  }

  /// A probe that keeps cutting past the window budget is rejected, not silently truncated.
  func testPlannerRefusesAFifteenthChunk() async throws {
    var planner = ChunkPlanner(
      overlapSamples: 0, silenceSearchStart: ChunkPlanner.minimumStride)
    planner.silenceProbe = { start, _ in
      .init(sample: start + 1, speechProbability: 0.01)
    }
    var previous: ChunkPlanner.Chunk?
    for _ in 0..<ChunkPlanner.maximumChunks {
      previous = try await planner.next(after: previous, sampleCount: 100_000_000)
      XCTAssertNotNil(previous)
    }
    do {
      _ = try await planner.next(after: previous, sampleCount: 100_000_000)
      XCTFail("a fifteenth chunk must be rejected")
    } catch {}
  }

  func testShortRecordingIsOneFinalChunkAndNoAudioIsDropped() async throws {
    let chunks = try await plan(ChunkPlanner(), samples: 160_000)
    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual(chunks[0].boundary, "final")
    XCTAssertEqual(chunks[0].sampleCount, 160_000)
  }

  func testVADPreferredUsesOnlyQualifyingCandidatesAndFallsBackContiguously() async throws {
    var preferred = ChunkPlanner(
      overlapSamples: 0, silenceSearchStart: ChunkPlanner.minimumStride,
      maximumSpeechProbability: 0.2)
    preferred.silenceProbe = { start, _ in
      .init(sample: start + 4_096, speechProbability: 0.21)
    }
    let fallback = try await plan(preferred, samples: 500_000)
    XCTAssertEqual(fallback.map(\.boundary), ["nominal_fallback", "nominal_fallback", "final"])
    XCTAssertEqual(fallback[1].sampleStart, ChunkPlanner.maximumSamples)

    preferred.silenceProbe = { start, _ in
      .init(sample: start + 4_096, speechProbability: 0.2)
    }
    let selected = try await plan(preferred, samples: 500_000)
    XCTAssertEqual(selected.first?.boundary, "vad_selected")
    XCTAssertEqual(selected.first?.sampleCount, ChunkPlanner.minimumStride + 4_096)
    XCTAssertEqual(selected[1].sampleStart, selected[0].sampleCount)
    XCTAssertEqual(selected.map(\.sampleCount).reduce(0, +), 500_000)
  }

  func testVADPreferredDoesNotCreateTinyTerminalChunk() async throws {
    var planner = ChunkPlanner(
      overlapSamples: 0, silenceSearchStart: ChunkPlanner.minimumStride,
      maximumSpeechProbability: 0.2)
    planner.silenceProbe = { _, _ in
      .init(sample: 208_000, speechProbability: 0.1)
    }

    let chunks = try await plan(planner, samples: 450_000)

    XCTAssertEqual(chunks.map(\.boundary), ["nominal_fallback", "final"])
    XCTAssertEqual(chunks.map(\.sampleStart), [0, 239_360])
    XCTAssertEqual(chunks.map(\.sampleCount), [239_360, 210_640])
  }
}
