import AVFoundation
import XCTest

@testable import LocalFlow
@testable import LocalFlowSpeech

final class AudioCaptureTests: XCTestCase {
  func testRaisedObjectiveCExceptionIsReturnedInsteadOfCrashing() {
    XCTAssertNil(LFCatchException {})
    let reason = LFCatchException {
      NSException(name: .invalidArgumentException, reason: "format mismatch").raise()
    }
    XCTAssertEqual(reason, "format mismatch")
  }

  func testRingPreservesOrderThroughWraparound() throws {
    let ring = try AudioCaptureStaging(channels: 1, sampleRate: 16_000)
    for batch in 0..<3 {
      for index in 0..<32 {
        XCTAssertTrue(ring.pushForTesting([Float(batch * 32 + index)], frames: 1))
      }
      for index in 0..<32 {
        XCTAssertEqual(ring.popForTesting(), [Float(batch * 32 + index)])
      }
      XCTAssertNil(ring.popForTesting())
    }
  }

  func testOverflowLatchesFailureWithoutOverwritingAcceptedAudio() throws {
    let ring = try AudioCaptureStaging(channels: 1, sampleRate: 16_000)
    for index in 0..<32 {
      XCTAssertTrue(ring.pushForTesting([Float(index)], frames: 1))
    }
    XCTAssertFalse(ring.pushForTesting([99], frames: 1))
    XCTAssertEqual(ring.failure, .overflow)
    for index in 0..<32 { XCTAssertEqual(ring.popForTesting(), [Float(index)]) }
    XCTAssertFalse(ring.pushForTesting([100], frames: 1))
  }

  func testHardwareCallbackLargerThanOneSlotIsSplitWithoutLosingSamples() throws {
    let ring = try AudioCaptureStaging(channels: 2, sampleRate: 48_000)
    let samples = (0..<(4_800 * 2)).map { Float($0) }
    XCTAssertTrue(ring.pushForTesting(samples, frames: 4_800))
    XCTAssertEqual(ring.popForTesting(), Array(samples.prefix(4_096 * 2)))
    XCTAssertEqual(ring.popForTesting(), Array(samples.dropFirst(4_096 * 2)))
    XCTAssertNil(ring.failure)
    XCTAssertNil(ring.popForTesting())
  }

  func testPlanarHardwareCallbackSplitsAcrossSlotsInOrder() throws {
    let ring = try AudioCaptureStaging(channels: 2, sampleRate: 48_000)
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
    buffer.frameLength = 4_800
    let channels = try XCTUnwrap(buffer.floatChannelData)
    for frame in 0..<4_800 {
      channels[0][frame] = Float(frame)
      channels[1][frame] = Float(-frame)
    }
    XCTAssertTrue(LFAudioRingPush(ring.pointer, buffer.audioBufferList, buffer.frameLength))
    let first = try XCTUnwrap(ring.popForTesting())
    let second = try XCTUnwrap(ring.popForTesting())
    XCTAssertEqual(first.count, 4_096 * 2)
    XCTAssertEqual(second.count, (4_800 - 4_096) * 2)
    XCTAssertEqual(first + second, (0..<4_800).flatMap { [Float($0), Float(-$0)] })
  }

  func testCallbackExceedingAvailableSlotsFailsWithoutPartialCopy() throws {
    let ring = try AudioCaptureStaging(channels: 1, sampleRate: 48_000)
    for _ in 0..<31 { XCTAssertTrue(ring.pushForTesting([1], frames: 1)) }
    XCTAssertFalse(ring.pushForTesting(Array(repeating: 2, count: 4_800), frames: 4_800))
    XCTAssertEqual(ring.failure, .overflow)
    for _ in 0..<31 { XCTAssertEqual(ring.popForTesting(), [1]) }
    XCTAssertNil(ring.popForTesting())
  }

  func testMaximumMultichannelBlockAndStopDrain() throws {
    let ring = try AudioCaptureStaging(channels: 8, sampleRate: 192_000)
    let samples = (0..<(4_096 * 8)).map { Float($0 % 8) }
    XCTAssertTrue(ring.pushForTesting(samples, frames: 4_096))
    ring.closeAndJoin()
    XCTAssertFalse(ring.pushForTesting(samples, frames: 4_096))
    XCTAssertEqual(ring.popForTesting(), samples)
    XCTAssertNil(ring.popForTesting())
  }

  func testUnsupportedFormatsAreRejectedBeforeCapture() {
    XCTAssertThrowsError(try AudioCaptureStaging(channels: 9, sampleRate: 16_000))
    XCTAssertThrowsError(try AudioCaptureStaging(channels: 1, sampleRate: 192_001))
    XCTAssertThrowsError(try AudioCaptureStaging(channels: 0, sampleRate: 16_000))
    XCTAssertThrowsError(try AudioCaptureStaging(channels: 1, sampleRate: 0))
  }

  func testSampleBudgetClipsFinalBlockAndDurationWinsAtDeadline() {
    var budget = AudioCaptureBudget(startNanoseconds: 10)
    for _ in 0..<1_799 { XCTAssertEqual(budget.accept(1_600), 1_600) }
    XCTAssertEqual(budget.accept(1_599), 1_599)
    XCTAssertEqual(budget.accept(1_600), 1)
    XCTAssertEqual(budget.accept(1), 0)
    XCTAssertTrue(budget.reachedLimit)
    let early = AudioCaptureBudget(startNanoseconds: 10)
    XCTAssertFalse(early.deadlineReached(at: 179_999_000_010))
    XCTAssertFalse(early.deadlineReached(at: 180_000_000_009))
    XCTAssertTrue(early.deadlineReached(at: 180_000_000_010))
  }

  func testStereoConversionSplitsIntoBoundedMonoSpoolWrites() throws {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      UUID().uuidString)
    let spool = try AudioSpool(rootDirectory: root)
    defer {
      try? spool.cleanup()
      try? FileManager.default.removeItem(at: root)
    }
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
    let normalizer = try AudioCaptureNormalizer(format: format, spool: spool)
    normalizer.input.frameLength = 4_096
    let channels = try XCTUnwrap(normalizer.input.floatChannelData)
    for index in 0..<4_096 {
      channels[0][index] = 0.25
      channels[1][index] = 0.75
    }
    try normalizer.convert(endOfStream: false)
    try normalizer.convert(endOfStream: true)
    XCTAssertEqual(normalizer.budget.sampleCount, 1_365, accuracy: 1)
    XCTAssertEqual(spool.bytesWritten, normalizer.budget.sampleCount * 4)
    let samples = try spool.readWindow(startSample: 0, count: normalizer.budget.sampleCount)
    XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) <= 1 })
    XCTAssertEqual(samples[500], 0.5, accuracy: 0.02)
  }

  func testLowRateConversionUsesSeveralBoundedOutputBlocks() throws {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      UUID().uuidString)
    let spool = try AudioSpool(rootDirectory: root)
    defer {
      try? spool.cleanup()
      try? FileManager.default.removeItem(at: root)
    }
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 1, interleaved: false))
    let normalizer = try AudioCaptureNormalizer(format: format, spool: spool)
    normalizer.input.frameLength = 4_096
    let channel = try XCTUnwrap(normalizer.input.floatChannelData?[0])
    for index in 0..<4_096 { channel[index] = 0.25 }
    try normalizer.convert(endOfStream: false)
    try normalizer.convert(endOfStream: true)
    XCTAssertEqual(normalizer.budget.sampleCount, 8_192)
    XCTAssertEqual(spool.bytesWritten, 8_192 * 4)
  }

  func testFailedSpoolDoesNotAdvanceNormalizedSampleCount() throws {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      UUID().uuidString)
    let spool = try AudioSpool(rootDirectory: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
    let normalizer = try AudioCaptureNormalizer(format: format, spool: spool)
    normalizer.input.frameLength = 1_024
    let channel = try XCTUnwrap(normalizer.input.floatChannelData?[0])
    for index in 0..<1_024 { channel[index] = 0.25 }
    try spool.cleanup()
    XCTAssertThrowsError(try normalizer.convert(endOfStream: false)) {
      XCTAssertEqual($0 as? AudioCaptureFailure, .disk)
    }
    XCTAssertEqual(normalizer.budget.sampleCount, 0)
  }

  func testConverterClipsTheFinalPermittedSample() throws {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      UUID().uuidString)
    let spool = try AudioSpool(rootDirectory: root)
    defer {
      try? spool.cleanup()
      try? FileManager.default.removeItem(at: root)
    }
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
    let normalizer = try AudioCaptureNormalizer(format: format, spool: spool)
    _ = normalizer.budget.accept(AudioCaptureBudget.maximumSamples - 1)
    normalizer.input.frameLength = 1_024
    let channel = try XCTUnwrap(normalizer.input.floatChannelData?[0])
    for index in 0..<1_024 { channel[index] = 0.25 }
    try normalizer.convert(endOfStream: false)
    try normalizer.convert(endOfStream: true)
    XCTAssertEqual(spool.bytesWritten, 4)
    XCTAssertEqual(normalizer.budget.sampleCount, AudioCaptureBudget.maximumSamples)
  }

  /// The queue peak feeds local resource records, so it must track the real
  /// occupancy and stay inside the capacity that a rejected push never exceeds.
  func testQueuePeakTracksOccupancyAndNeverExceedsCapacity() throws {
    let ring = try AudioCaptureStaging(channels: 1, sampleRate: 16_000)
    XCTAssertEqual(ring.queuePeak.capacity, 32)
    XCTAssertEqual(ring.queuePeak.highWater, 0)
    for index in 0..<4 { XCTAssertTrue(ring.pushForTesting([Float(index)], frames: 1)) }
    XCTAssertEqual(ring.queuePeak.highWater, 4)
    for _ in 0..<4 { _ = ring.popForTesting() }
    XCTAssertEqual(ring.queuePeak.highWater, 4, "The peak records the maximum, not the depth")
    for index in 0..<32 { XCTAssertTrue(ring.pushForTesting([Float(index)], frames: 1)) }
    XCTAssertEqual(ring.queuePeak.highWater, 32)
    XCTAssertFalse(ring.pushForTesting([99], frames: 1))
    XCTAssertEqual(ring.queuePeak.highWater, 32, "A rejected push cannot raise the peak")
    XCTAssertLessThanOrEqual(ring.queuePeak.highWater, ring.queuePeak.capacity)
  }

  // MARK: Feature 019 — input binding (T008)

  private func makeSpool() throws -> (AudioSpool, URL) {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      UUID().uuidString)
    return (try AudioSpool(rootDirectory: root), root)
  }

  func testDeviceBindingFailureIsDeviceLossAndLeavesTheSpoolEmpty() async throws {
    let (spool, root) = try makeSpool()
    defer {
      try? spool.cleanup()
      try? FileManager.default.removeItem(at: root)
    }
    struct BindFailure: Error {}
    let service = AudioCaptureService(
      openInput: { _ in throw BindFailure() }, permission: { .authorized })
    do {
      _ = try await service.start(sessionID: UUID(), spool: spool, input: .device(42))
      XCTFail("binding must fail")
    } catch {
      XCTAssertEqual(error as? AudioCaptureFailure, .deviceLost)
    }
    XCTAssertEqual(spool.bytesWritten, 0)
    let snapshot = await service.snapshot()
    XCTAssertNil(snapshot, "no session was left behind")
  }

  func testPermissionIsCheckedBeforeBinding() async throws {
    let (spool, root) = try makeSpool()
    defer {
      try? spool.cleanup()
      try? FileManager.default.removeItem(at: root)
    }
    let bound = AtomicFlag()
    let service = AudioCaptureService(
      openInput: { _ in
        bound.set(true)
        throw AudioCaptureFailure.deviceLost
      }, permission: { .denied })
    do {
      _ = try await service.start(sessionID: UUID(), spool: spool, input: .device(42))
      XCTFail("permission must fail")
    } catch {
      XCTAssertEqual(error as? AudioCaptureFailure, .permissionDenied)
    }
    XCTAssertFalse(bound.value)
  }

  func testStopWithAndWithoutTailIsStaleForAnUnknownSessionAndNeverWaits() async throws {
    let service = AudioCaptureService(permission: { .authorized })
    let clock = ContinuousClock()
    let started = clock.now
    for tail in [nil, Duration.milliseconds(400)] {
      do {
        _ = try await service.stop(sessionID: UUID(), tail: tail)
        XCTFail("no session")
      } catch {
        XCTAssertEqual(error as? AudioCaptureFailure, .staleSession)
      }
    }
    XCTAssertLessThan(clock.now - started, .milliseconds(300), "no tail without a session")
  }

  func testALatchedFailureWinsOverKeyReleaseAndCancel() {
    for cancelling in [false, true] {
      XCTAssertEqual(
        AudioCaptureService.stopReason(
          ringFailure: .deviceLost, authorized: true, running: true, limitReached: false,
          cancelling: cancelling), .failure(.deviceLost))
    }
    XCTAssertEqual(
      AudioCaptureService.stopReason(
        ringFailure: nil, authorized: true, running: true, limitReached: false, cancelling: false),
      .keyRelease)
    XCTAssertEqual(
      AudioCaptureService.stopReason(
        ringFailure: nil, authorized: true, running: false, limitReached: false,
        cancelling: false), .failure(.deviceLost))
    XCTAssertEqual(
      AudioCaptureService.stopReason(
        ringFailure: nil, authorized: true, running: true, limitReached: true, cancelling: false),
      .durationLimit)
  }

  // MARK: Feature 019 — first-audio gate and delivery delay (T031)

  func testAllZeroPushesLeaveFirstAudioUnsetAndTheFirstNonZeroSetsItOnce() throws {
    let ring = try AudioCaptureStaging(channels: 2, sampleRate: 48_000)
    XCTAssertTrue(ring.pushForTesting(Array(repeating: 0, count: 64), frames: 32))
    XCTAssertNil(ring.firstAudioNanoseconds)
    var samples = Array(repeating: Float(0), count: 64)
    samples[63] = 0.001
    XCTAssertTrue(ring.pushForTesting(samples, frames: 32))
    let first = try XCTUnwrap(ring.firstAudioNanoseconds)
    XCTAssertTrue(ring.pushForTesting(Array(repeating: 0.5, count: 64), frames: 32))
    XCTAssertEqual(ring.firstAudioNanoseconds, first)
  }

  func testMaxDeliveryDelayKeepsTheSessionMaximum() throws {
    let ring = try AudioCaptureStaging(channels: 1, sampleRate: 48_000)
    XCTAssertEqual(ring.maxDeliveryDelay, .zero)
    ring.recordDeliveryDelay(nanoseconds: 30_000_000)
    ring.recordDeliveryDelay(nanoseconds: 320_000_000)
    ring.recordDeliveryDelay(nanoseconds: 40_000_000)
    XCTAssertEqual(ring.maxDeliveryDelay, .milliseconds(320))
  }

  func testLeadingSilenceIsNotSpooledAndTheBudgetStartsWhenAudioFlows() throws {
    let (spool, root) = try makeSpool()
    defer {
      try? spool.cleanup()
      try? FileManager.default.removeItem(at: root)
    }
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
    let normalizer = try AudioCaptureNormalizer(format: format, spool: spool)
    normalizer.budget = .notStarted
    let channel = try XCTUnwrap(normalizer.input.floatChannelData?[0])
    normalizer.input.frameLength = 1_024
    for index in 0..<1_024 { channel[index] = 0 }
    XCTAssertFalse(normalizer.admitInput(flowingAt: 100))
    XCTAssertNil(normalizer.flowingSince)
    XCTAssertEqual(spool.bytesWritten, 0, "a cancel now leaves an empty spool")
    XCTAssertFalse(normalizer.budget.deadlineReached(at: .max - 1), "no clock before audio")
    channel[512] = 0.25
    XCTAssertTrue(normalizer.admitInput(flowingAt: 5_000))
    try normalizer.convert(endOfStream: false)
    try normalizer.convert(endOfStream: true)
    XCTAssertEqual(normalizer.flowingSince, 5_000)
    XCTAssertEqual(normalizer.budget.startNanoseconds, 5_000)
    XCTAssertGreaterThan(spool.bytesWritten, 0)
    for index in 0..<1_024 { channel[index] = 0 }
    XCTAssertTrue(normalizer.admitInput(flowingAt: 9_000), "after audio flows, silence is kept")
    XCTAssertEqual(normalizer.flowingSince, 5_000, "set once")
    XCTAssertTrue(normalizer.budget.deadlineReached(at: 5_000 + 180_000_000_000))
  }

  func testInterleavedSilenceIsDetected() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
    buffer.frameLength = 16
    let data = try XCTUnwrap(buffer.floatChannelData?[0])
    for index in 0..<32 { data[index] = 0 }
    XCTAssertFalse(AudioCaptureNormalizer.containsAudio(buffer))
    data[31] = -0.1
    XCTAssertTrue(AudioCaptureNormalizer.containsAudio(buffer))
  }
}
