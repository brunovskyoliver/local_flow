import AVFoundation
import XCTest

@testable import LocalFlow

@MainActor
final class TranscriptInstrumentationTests: XCTestCase {
  func testLiveStopFailedFinalizationAndRetryKeepMetricsAndLogsContentFree() async throws {
    let phrases = ["spoken apricot telescope", "spoken violet badger", "spoken copper penguin"]
    let note = "private notebook juniper"
    let fixture = try MeetingTestStore.make()
    defer { fixture.cleanup() }
    let meeting = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init(microphone: .blocks(152), system: .missing)])
    let id = meeting.meetingID
    let notes = try await fixture.store.notes(meetingID: id)
    _ = try await fixture.store.saveNotes(
      meetingID: id, text: note, revision: XCTUnwrap(notes).revision, now: 1)
    let capture = try RecorderCapture.make()
    defer { capture.cleanup() }
    let logs = TranscriptLogCapture()
    let clock = FakeMeetingClock()
    let runtime = InstrumentedTranscriptRuntime(clock: clock, phrases: phrases, secret: note)
    let lifecycle = ModelLifecycleCoordinator { runtime }
    let store = TranscriptStore(database: fixture.history.database)
    let finalizer = MeetingFinalizer(
      store: store, meetings: fixture.store, storageRoot: fixture.root,
      lifecycle: lifecycle, clock: clock, recorder: capture.recorder,
      logSink: { logs.append($0) })
    let coordinator = MeetingTranscriptionCoordinator(
      store: store, lifecycle: lifecycle, clock: clock, recorder: capture.recorder,
      finalizer: finalizer, logSink: { logs.append($0) })
    _ = await coordinator.meetingWillStart(id: id, options: .init(transcription: true))
    let taps = try XCTUnwrap(
      coordinator.stretchDidStart(
        meetingID: id, sequence: 1,
        tracks: [.microphone: .init(sampleRate: 48_000, channels: 1)]))
    await settle { coordinator.status?.state == .live }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!
    block.frameLength = 4_096
    block.floatChannelData![0].initialize(repeating: 0.25, count: 4_096)
    for window in 1...2 {
      for _ in 0..<76 {
        taps[.microphone]?.push(block)
        await coordinator.tick()
        await Task.yield()
      }
      await settle {
        !coordinator.isWindowInFlight
          && coordinator.pendingSegmentCount + (coordinator.status?.provisionalCount ?? 0) >= window
      }
    }
    coordinator.meetingDidStop(id: id)
    await settle { coordinator.status?.state == .finalizing }
    let provisional = try await store.page(
      meetingID: id, finality: .provisional, after: nil, limit: 200)
    XCTAssertTrue(provisional.contains { $0.draft.rawText.contains(phrases[0]) })
    // Both complete live windows finish recognition before stop flushes their text.
    XCTAssertTrue(provisional.contains { $0.draft.rawText.contains(phrases[1]) })
    await runtime.beginFinalization()
    let detail = try await fixture.store.detail(id: id)
    coordinator.meetingDidComplete(id: id, detail: try XCTUnwrap(detail))
    await settle { coordinator.status?.state == .failed && !coordinator.isFinalizing }
    XCTAssertEqual(coordinator.status?.failure, .runtimeFailure)
    let failed = try await store.transcription(meetingID: id)
    coordinator.requestFinalization(meetingID: id, revision: try XCTUnwrap(failed).revision)
    await settle { coordinator.status?.state == .final && !coordinator.isFinalizing }
    let final = try await store.page(meetingID: id, finality: .final, after: nil, limit: 200)
    XCTAssertTrue(final.contains { $0.draft.rawText.contains(phrases[2]) })
    await coordinator.shutdown()
    let report = try await capture.recorder.close()
    XCTAssertTrue(report.complete)
    let samples = try await capture.samples()
    let transitions = samples.filter { $0["metric"] as? String == "transcriptTransition" }
    let live = try XCTUnwrap(
      transitions.firstIndex {
        $0["phase"] as? String == "transcriptLive" && $0["meetingKey"] as? String == "live"
      })
    let failedIndex = try XCTUnwrap(
      transitions.firstIndex {
        $0["phase"] as? String == "transcriptFinalizing" && $0["meetingKey"] as? String == "failed"
      })
    let finalIndex = try XCTUnwrap(
      transitions.firstIndex { $0["meetingKey"] as? String == "final" })
    XCTAssertLessThan(live, failedIndex)
    XCTAssertLessThan(failedIndex, finalIndex)
    XCTAssertTrue(
      transitions[..<failedIndex].contains {
        $0["phase"] as? String == "transcriptFinalizing"
          && $0["meetingKey"] as? String == "finalizing"
      })
    let finalizationRSS = samples.filter {
      $0["phase"] as? String == "transcriptFinalizing"
        && (($0["rssBytes"] as? NSNumber)?.uint64Value ?? 0) > 0
    }
    XCTAssertGreaterThanOrEqual(finalizationRSS.count, 2, "RSS sampling survives failure and retry")
    let rtf = try XCTUnwrap(samples.first { $0["metric"] as? String == "transcriptRealTimeFactor" })
    let audioSamples = await runtime.successfulFinalSamples
    let expected = 12.0 * 16_000 / Double(audioSamples)
    XCTAssertEqual(
      try XCTUnwrap(rtf["durationNanoseconds"] as? Double) / 1e9, expected, accuracy: 1e-9)
    XCTAssertTrue(
      logs.messages.contains { $0.contains("finalization failed category=runtime_failure") })
    XCTAssertTrue(logs.messages.contains { $0.contains("finalization complete") })
    let exported = report.files.compactMap { try? Data(contentsOf: $0) }.reduce(Data(), +)
    let allOutput =
      String(decoding: exported, as: UTF8.self) + logs.messages.joined(separator: "\n")
    for secret in phrases + [note] { XCTAssertFalse(allOutput.contains(secret)) }
    let pcm = Data(bytes: block.floatChannelData![0], count: 4_096 * MemoryLayout<Float>.size)
    XCTAssertNil(Data(allOutput.utf8).range(of: pcm.prefix(64)))
    XCTAssertFalse(allOutput.contains(pcm.prefix(64).base64EncodedString()))
    XCTAssertFalse(allOutput.contains(Array(repeating: "0.25", count: 16).joined(separator: ",")))
    XCTAssertFalse(allOutput.contains(Array(repeating: "0.25", count: 16).joined(separator: ", ")))
  }

  private func settle(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<1_000 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Transcript instrumentation run did not settle")
  }
}

private final class TranscriptLogCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []
  var messages: [String] { lock.withLock { storage } }
  func append(_ message: String) { lock.withLock { storage.append(message) } }
}

private actor InstrumentedTranscriptRuntime: TranscriptionRuntime {
  let clock: FakeMeetingClock
  let phrases: [String]
  let secret: String
  var liveCalls = 0
  var finalizing = false
  var shouldFail = true
  private(set) var successfulFinalSamples = 0
  init(clock: FakeMeetingClock, phrases: [String], secret: String) {
    self.clock = clock
    self.phrases = phrases
    self.secret = secret
  }
  func beginFinalization() { finalizing = true }
  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    if !finalizing {
      defer { liveCalls += 1 }
      return .init(text: phrases[min(liveCalls, 1)], tokens: [])
    }
    await clock.advance(by: .seconds(12))
    if shouldFail {
      shouldFail = false
      throw NSError(domain: phrases[2], code: 1, userInfo: [NSLocalizedDescriptionKey: secret])
    }
    successfulFinalSamples += samples.count
    return .init(text: phrases[2], tokens: [])
  }
  func shutdown() {}
}
