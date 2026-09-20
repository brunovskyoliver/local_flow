import XCTest

@testable import LocalFlow

final class TranscriptSegmenterTests: XCTestCase {
  private func window(_ words: [String], gapAt: Int? = nil, timings: Bool = true) -> AssembledWindow
  {
    let text = words.joined(separator: " ")
    var offset = 0
    let tokens = words.enumerated().map { index, word in
      defer { offset += word.utf8.count + 1 }
      let time = Double(index) * 0.1 + (gapAt.map { index >= $0 ? 1.0 : 0 } ?? 0)
      return TranscriptAssembler.Token(
        text: word, utf8Start: offset, utf8End: offset + word.utf8.count,
        startSeconds: time, endSeconds: time + 0.05)
    }
    var assembler = MeetingWindowAssembler()
    return assembler.append(
      window: .init(
        sequence: 0, sampleStart: 0, sampleCount: 96_000,
        paddedSampleCount: 96_000, text: text, tokens: timings ? tokens : nil))
  }
  private let base = StreamPosition(stretchSequence: 1, stretchBaseMs: 10_000, tracks: .both)

  func testPunctuationWordMinimumGapAndFortyWordCap() {
    let segmenter = TranscriptSegmenter()
    let punctuation = segmenter.segments(
      window: window(["One.", "two", "three!", "four"]), base: base)
    XCTAssertEqual(punctuation.map(\.rawText), ["One. two three!", "four"])
    XCTAssertEqual(
      segmenter.segments(window: window(["one", "two", "three"], gapAt: 2), base: base).count, 2)
    XCTAssertEqual(
      segmenter.segments(window: window(Array(repeating: "word", count: 45)), base: base).count, 2)
  }

  /// Feature 009 tokens are native whisper.cpp phrases; the word rules count the
  /// words inside them, so one three-word phrase ending in a period already cuts,
  /// and eight 6-word phrases split at the cap rather than running to 40 phrases.
  func testPhraseTokensCountTheirWords() {
    let segmenter = TranscriptSegmenter()
    XCTAssertEqual(TranscriptSegmenter.version, "segmenter_gap0.8_punct_words_v2")
    let phrases = segmenter.segments(
      window: window(["One two three.", "four five", "six seven eight."]), base: base)
    XCTAssertEqual(phrases.map(\.rawText), ["One two three.", "four five six seven eight."])
    let capped = segmenter.segments(
      window: window(Array(repeating: "a b c d e f", count: 8)), base: base)
    XCTAssertEqual(capped.count, 2)
    XCTAssertEqual(capped[0].rawText.split(separator: " ").count, 42)
  }

  func testMissingTimingsFallbackEmptyAndExactUnicodeBytes() {
    let segmenter = TranscriptSegmenter()
    let fallback = segmenter.segments(
      window: window(["cafe\u{301}", "word"], timings: false), base: base)
    XCTAssertEqual(fallback.count, 1)
    XCTAssertEqual(fallback.first?.timingBasis, .window)
    XCTAssertEqual(fallback.first?.startMs, 10_000)
    XCTAssertEqual(fallback.first?.endMs, 16_000)
    XCTAssertEqual(Array(fallback[0].rawText.utf8), Array("cafe\u{301} word".utf8))
    XCTAssertTrue(segmenter.segments(window: window([]), base: base).isEmpty)
  }

  func testByteCapSplitsBeforeWordAndPreservesRawBytes() {
    let word = String(repeating: "é", count: 700)
    let segments = TranscriptSegmenter().segments(
      window: window([word, word, word, word]), base: base)
    XCTAssertEqual(segments.count, 2)
    XCTAssertTrue(segments.allSatisfy { $0.rawText.utf8.count <= 4_096 && $0.endMs > $0.startMs })
    XCTAssertEqual(
      segments.map(\.rawText).joined(separator: " "),
      [word, word, word, word].joined(separator: " "))
  }
  func testTimingsClampToWindowAndInvalidMappingFallsBack() {
    var assembler = MeetingWindowAssembler()
    let source = TranscriptAssembler.Window(
      sequence: 0, sampleStart: 0, sampleCount: 96_000,
      paddedSampleCount: 96_000, text: "word",
      tokens: [
        .init(text: "word", utf8Start: 0, utf8End: 4, startSeconds: -0.5, endSeconds: 9)
      ])
    let segments = TranscriptSegmenter().segments(
      window: assembler.append(window: source), base: base)
    XCTAssertEqual(segments.first?.timingBasis, .word)
    XCTAssertEqual(segments.first?.startMs, 10_000)
    XCTAssertEqual(segments.first?.endMs, 16_000)
    let invalid = TranscriptAssembler.Window(
      sequence: 1, sampleStart: 96_000, sampleCount: 96_000,
      paddedSampleCount: 96_000, text: "other word",
      tokens: [
        .init(text: "word", utf8Start: 6, utf8End: 10, startSeconds: 0, endSeconds: 1)
      ])
    XCTAssertEqual(
      TranscriptSegmenter().segments(window: assembler.append(window: invalid), base: base).first?
        .timingBasis, .window)
  }

  func testFallbackByteSplitKeepsWholeWordsAndReasonsContainCountsOnly() {
    let words = Array(repeating: String(repeating: "x", count: 1_000), count: 8)
    let output = TranscriptSegmenter().process(window: window(words, timings: false), base: base)
    XCTAssertTrue(output.segments.allSatisfy { $0.rawText.utf8.count <= 4_096 })
    XCTAssertEqual(output.segments.map(\.rawText).joined(), words.joined(separator: " "))
    XCTAssertTrue(output.segments.dropFirst().allSatisfy { $0.rawText.first == " " })
    let controls = TranscriptSegmenter().process(
      window: window(["word\u{0001}"], timings: false), base: base)
    XCTAssertEqual(controls.normalizationReasonCounts["unexpected_control"], 1)
  }

}
