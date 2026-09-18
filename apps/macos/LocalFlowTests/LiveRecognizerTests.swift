import XCTest

@testable import LocalFlow

@MainActor
final class LiveRecognizerTests: XCTestCase {
  func testBackpressureDropsWholeWindowsAndPreservesTimeline() async throws {
    let lifecycle = ModelLifecycleCoordinator { FakeTranscriptionRuntime() }
    let lease = try await lifecycle.acquire(session: UUID())
    let recognizer = LiveRecognizer(lifecycle: lifecycle, lease: lease, sequence: 1)
    recognizer.accept(Array(repeating: 0, count: 400_000), tracks: .mic, emittedAt: 0)
    let gaps = recognizer.applyBackpressure()
    XCTAssertEqual(gaps, [0..<288_000])
    XCTAssertEqual(recognizer.streamEnd - recognizer.consumedEnd, 112_000)
    _ = try await recognizer.processNext()
    XCTAssertEqual(recognizer.pendingBatch().first?.startMs, 18_000)
    XCTAssertEqual(recognizer.queue.highWater, 400_000)
    try await lifecycle.finish(lease)
  }

  func testSuspendedRefusalsAndTapGapsDoNotShiftLaterAudio() async throws {
    let lifecycle = ModelLifecycleCoordinator { FakeTranscriptionRuntime() }
    let lease = try await lifecycle.acquire(session: UUID())
    let recognizer = LiveRecognizer(lifecycle: lifecycle, lease: lease, sequence: 1)
    recognizer.accept(Array(repeating: 0, count: 480_000), tracks: .mic, emittedAt: 0)
    XCTAssertEqual(
      recognizer.accept(Array(repeating: 0, count: 16_000), tracks: .mic, emittedAt: 0), 0)
    XCTAssertEqual(recognizer.streamEnd, 496_000)
    XCTAssertTrue(recognizer.queue.suspended)
    _ = recognizer.applyBackpressure()
    while try await recognizer.processNext(tail: true) {}
    recognizer.insertGap(496_000..<512_000)
    recognizer.accept(Array(repeating: 0, count: 96_000), tracks: .mic, emittedAt: 0)
    _ = try await recognizer.processNext()
    XCTAssertEqual(recognizer.pendingBatch().last?.startMs, 32_000)
    XCTAssertEqual(recognizer.streamEnd, 608_000)
    XCTAssertLessThanOrEqual(recognizer.queue.highWater, 480_000)
    try await lifecycle.finish(lease)
  }

  func testSerialWindowsNormalizeAndTailRetainsExactCoverage() async throws {
    let runtime = FakeTranscriptionRuntime()
    let lifecycle = ModelLifecycleCoordinator { runtime }
    let lease = try await lifecycle.acquire(session: UUID())
    let recognizer = LiveRecognizer(lifecycle: lifecycle, lease: lease, sequence: 1)
    recognizer.accept(Array(repeating: 0.25, count: 193_600), tracks: .mic, emittedAt: 0)
    let result1 = try await recognizer.processNext()
    XCTAssertTrue(result1)
    let result2 = try await recognizer.processNext()
    XCTAssertTrue(result2)
    let result3 = try await recognizer.processNext()
    XCTAssertFalse(result3)
    let result4 = try await recognizer.processNext(tail: true)
    XCTAssertTrue(result4)
    let result5 = try await recognizer.processNext(tail: true)
    XCTAssertFalse(result5)
    let counts = await runtime.sampleCounts
    let concurrent = await runtime.maximumActive
    XCTAssertEqual(counts, [96_000, 96_000, 1_600])
    XCTAssertEqual(concurrent, 1)
    XCTAssertEqual(recognizer.pendingCount, 3)
    XCTAssertEqual(
      recognizer.pendingBatch().map(\.normalizedText), Array(repeating: "hello, world", count: 3))
    XCTAssertEqual(recognizer.windowBufferAllocationCount, 1)
    try await lifecycle.finish(lease)
  }

  func testRuntimeFailureDoesNotDiscardPreviousDrafts() async throws {
    let runtime = FakeTranscriptionRuntime(failureOnCall: 2)
    let lifecycle = ModelLifecycleCoordinator { runtime }
    let lease = try await lifecycle.acquire(session: UUID())
    let recognizer = LiveRecognizer(lifecycle: lifecycle, lease: lease, sequence: 1)
    recognizer.accept(Array(repeating: 0, count: 192_000), tracks: .mic, emittedAt: 0)
    _ = try await recognizer.processNext()
    do {
      _ = try await recognizer.processNext()
      XCTFail("Expected runtime failure")
    } catch {
      XCTAssertEqual(error as? LiveRecognizer.Failure, .runtimeFailure)
    }
    XCTAssertEqual(recognizer.pendingCount, 1)
    try await lifecycle.finish(lease)
  }

  func testLatencyUsesLastSampleEmissionAndBatchAcknowledgement() async throws {
    let clock = FakeMeetingClock(now: 1_000)
    let lifecycle = ModelLifecycleCoordinator { FakeTranscriptionRuntime() }
    let lease = try await lifecycle.acquire(session: UUID())
    let recognizer = LiveRecognizer(lifecycle: lifecycle, lease: lease, sequence: 1, clock: clock)
    recognizer.accept(Array(repeating: 0, count: 96_000), tracks: .mic, emittedAt: 500_000_000)
    _ = try await recognizer.processNext()
    XCTAssertEqual(recognizer.lastLatencyNanoseconds, 500_000_000)
    XCTAssertEqual(recognizer.pendingBatch().count, 1)
    XCTAssertEqual(recognizer.pendingCount, 1)
    recognizer.acknowledgeBatch(count: 1)
    XCTAssertEqual(recognizer.pendingCount, 0)
    try await lifecycle.finish(lease)
  }

  func testUnpersistedBufferRefusesSegment201() async throws {
    let lifecycle = ModelLifecycleCoordinator { FakeTranscriptionRuntime() }
    let lease = try await lifecycle.acquire(session: UUID())
    let recognizer = LiveRecognizer(lifecycle: lifecycle, lease: lease, sequence: 1)
    for _ in 0..<200 {
      recognizer.accept(Array(repeating: 0, count: 1_600), tracks: .mic, emittedAt: 0)
      _ = try await recognizer.processNext(tail: true)
    }
    recognizer.accept(Array(repeating: 0, count: 1_600), tracks: .mic, emittedAt: 0)
    do {
      _ = try await recognizer.processNext(tail: true)
      XCTFail("Expected bounded-buffer refusal")
    } catch {
      XCTAssertEqual(error as? LiveRecognizer.Failure, .persistenceFailure)
    }
    XCTAssertEqual(recognizer.pendingCount, 200)
    try await lifecycle.finish(lease)
  }
}
