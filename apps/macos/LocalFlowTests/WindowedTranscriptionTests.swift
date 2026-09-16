import XCTest

@testable import LocalFlow

final class WindowedTranscriptionTests: XCTestCase {
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
    await lifecycle.cancelAndJoin(lease)
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
